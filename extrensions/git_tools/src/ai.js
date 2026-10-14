// @ts-check
'use strict';

/**
 * AI commit message generation with Anthropic Claude or Google Gemini.
 * Uses the global fetch of the VS Code extension host (Node 18+).
 */

class AiError extends Error {
  /** @param {string} message @param {{cancelled?: boolean}} [o] */
  constructor(message, o = {}) {
    super(message);
    this.cancelled = !!o.cancelled;
  }
}

const SYSTEM_PROMPT = `You write git commit messages for the changes a developer is about to commit.

Write the message the way an experienced engineer on this project would:
- First line: a concise summary of what the change does, in the imperative mood ("Add", "Fix", "Refactor"), at most 72 characters, no trailing period.
- If the change is more than trivial, add a blank line and then a short body explaining what changed and why, wrapped at about 72 characters. Bullet points are fine for several independent changes. Skip the body for small, self-explanatory changes.
- Follow the conventions visible in the project's recent commit subjects (for example a "feat:"/"fix:" prefix, ticket ids, capitalization, language) when they are consistent.
- Describe the intent of the change, not a file-by-file narration. Do not invent motivations that the diff does not support.

Reply with the commit message only: no preamble, no quotes, no Markdown code fences.`;

/**
 * @typedef {{files: string[], diff: string, branch?: string, recentSubjects?: string[],
 *   language?: string, instructions?: string, amendOf?: string|null}} CommitRequest
 */

/** @param {CommitRequest} r */
function buildPrompt(r) {
  const lines = [];
  if (r.language && r.language.trim()) lines.push(`Write the commit message in ${r.language.trim()}.`, '');
  if (r.instructions && r.instructions.trim()) {
    lines.push('Additional instructions from the developer:', r.instructions.trim(), '');
  }
  if (r.branch) lines.push(`Branch: ${r.branch}`);
  if (r.recentSubjects && r.recentSubjects.length) {
    lines.push('', 'Recent commit subjects in this repository (newest first):', ...r.recentSubjects.map((s) => `- ${s}`));
  }
  if (r.amendOf) lines.push('', 'This amends the previous commit, whose current message is:', r.amendOf);
  lines.push('', 'Files in this commit:', ...r.files, '', '<diff>', r.diff, '</diff>');
  return lines.join('\n');
}

/** Removes accidental code fences and surrounding whitespace. */
function clean(text) {
  let t = text.trim();
  if (t.startsWith('```')) {
    t = t.replace(/^```[a-zA-Z]*\n?/, '').replace(/\n?```$/, '');
  }
  return t.trim();
}

/** Extracts `error.message` from an object or list shaped JSON error. */
function errorMessageFrom(body) {
  try {
    let j = JSON.parse(body);
    if (Array.isArray(j)) j = j[0];
    if (j && j.error && typeof j.error.message === 'string') return j.error.message;
  } catch { /* not JSON */ }
  return null;
}

/** Yields SSE `data:` payloads from a fetch Response body. */
async function* sseData(response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buf = '';
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl).replace(/\r$/, '');
      buf = buf.slice(nl + 1);
      if (line.startsWith('data:')) {
        const data = line.slice(5).trim();
        if (data) yield data;
      }
    }
  }
  const last = buf.trim();
  if (last.startsWith('data:') && last.slice(5).trim()) yield last.slice(5).trim();
}

class CommitMessageAi {
  /** @param {{apiKey: string, model: string, endpoint?: string}} o */
  constructor(o) {
    this.apiKey = o.apiKey;
    this.model = o.model;
    this.endpoint = o.endpoint;
    /** @type {AbortController|null} */
    this.abort = null;
  }

  cancel() {
    if (this.abort) this.abort.abort();
  }

  /**
   * @param {CommitRequest} req
   * @param {(text: string) => void} onText receives the full text so far
   */
  async generate(req, onText) {
    const text = clean(await this.stream(SYSTEM_PROMPT, buildPrompt(req), (t) => onText(clean(t))));
    if (!text) throw new AiError('The model returned an empty message.');
    return text;
  }

  async testConnection() {
    const t = await this.stream('You are a connectivity check.', 'Reply with the single word OK.', () => {});
    if (!t.trim()) throw new AiError('The model returned an empty reply.');
  }

  /**
   * @param {string} url
   * @param {Record<string,string>} headers
   * @param {object} body
   * @param {(data: string) => boolean|void} onData return true to stop
   * @param {(status: number, body: string) => string} httpError
   */
  async post(url, headers, body, onData, httpError) {
    this.abort = new AbortController();
    let response;
    try {
      response = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json', ...headers },
        body: JSON.stringify(body),
        signal: this.abort.signal,
      });
      if (!response.ok) {
        throw new AiError(httpError(response.status, await response.text()));
      }
      for await (const data of sseData(response)) {
        if (onData(data)) break;
      }
    } catch (e) {
      if (e instanceof AiError) throw e;
      if (this.abort.signal.aborted) throw new AiError('Cancelled', { cancelled: true });
      if (e instanceof SyntaxError) throw new AiError(`Unexpected response: ${e.message}`);
      const cause = e && e.cause && e.cause.message ? ` (${e.cause.message})` : '';
      throw new AiError(`Network error: ${e && e.message ? e.message : e}${cause}`);
    } finally {
      this.abort = null;
    }
  }
}

/** Models that accept the server-side `fallbacks: "default"` option. */
const CLAUDE_FALLBACK_MODELS = new Set(['claude-opus-5-5', 'claude-opus-5', 'claude-fable-5-1', 'claude-sonnet-5-5']);

class ClaudeCommitAi extends CommitMessageAi {
  async stream(system, user, onText) {
    const fallback = CLAUDE_FALLBACK_MODELS.has(this.model);
    const effort = /^claude-(opus-(5|4-[5-8])|fable-5|sonnet-(5|4-6)|haiku-5)/.test(this.model);
    let text = '';
    let stopReason = null;
    /** @type {Record<string,string>} */
    const headers = { 'x-api-key': this.apiKey, 'anthropic-version': '2023-06-01' };
    if (fallback) headers['anthropic-beta'] = 'server-side-fallback-2026-07-01';
    /** @type {Record<string, any>} */
    const body = {
      model: this.model,
      max_tokens: 16000,
      stream: true,
      system,
      messages: [{ role: 'user', content: user }],
    };
    // Commit messages are a light task.
    if (effort) body.output_config = { effort: 'low' };
    // Re-run a safety-classifier decline on Anthropic's recommended model.
    if (fallback) body.fallbacks = 'default';

    await this.post(this.endpoint || 'https://api.anthropic.com/v1/messages', headers, body, (data) => {
      const ev = JSON.parse(data);
      if (ev.type === 'content_block_start' && ev.content_block && ev.content_block.type === 'fallback') {
        // The declined model's partial output is replaced by the fallback answer.
        text = '';
        onText(text);
      } else if (ev.type === 'content_block_delta' && ev.delta && ev.delta.type === 'text_delta') {
        text += ev.delta.text;
        onText(text);
      } else if (ev.type === 'message_delta' && ev.delta) {
        stopReason = ev.delta.stop_reason || stopReason;
      } else if (ev.type === 'error') {
        throw new AiError((ev.error && ev.error.message) || 'Streaming error');
      }
    }, (status, b) => {
      const msg = errorMessageFrom(b);
      const hint = {
        401: 'Invalid Claude API key.',
        403: 'This API key is not allowed to use this model.',
        404: `Unknown Claude model "${this.model}".`,
        429: 'Claude rate limit reached. Try again in a moment.',
        529: 'The Claude API is overloaded. Try again in a moment.',
      }[status] || `Claude API error (HTTP ${status}).`;
      return msg ? `${hint} ${msg}` : hint;
    });
    if (stopReason === 'refusal') throw new AiError('Claude declined this request.');
    return text;
  }
}

class GeminiCommitAi extends CommitMessageAi {
  async stream(system, user, onText) {
    let text = '';
    let finish = null;
    await this.post(
      this.endpoint || 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
      { authorization: `Bearer ${this.apiKey}` },
      {
        model: this.model,
        stream: true,
        // Little reasoning is needed; saves free-tier tokens and time.
        reasoning_effort: 'low',
        messages: [
          { role: 'system', content: system },
          { role: 'user', content: user },
        ],
      },
      (data) => {
        if (data === '[DONE]') return true;
        const ev = JSON.parse(data);
        if (ev.error) throw new AiError(errorMessageFrom(data) || 'Gemini streaming error');
        for (const c of ev.choices || []) {
          const content = c.delta && c.delta.content;
          if (typeof content === 'string' && content) {
            text += content;
            onText(text);
          }
          finish = c.finish_reason || finish;
        }
        return false;
      },
      (status, b) => {
        const msg = errorMessageFrom(b);
        const hint = {
          400: 'Gemini rejected the request (check the model name and API key).',
          401: 'Invalid Gemini API key.',
          403: 'Invalid Gemini API key or the key has no access to this model.',
          404: `Unknown Gemini model "${this.model}".`,
          429: 'Gemini quota exceeded (free tier limit reached). Try later or switch model.',
          503: 'Gemini is overloaded. Try again in a moment.',
        }[status] || `Gemini API error (HTTP ${status}).`;
        return msg ? `${hint} ${msg}` : hint;
      },
    );
    if (finish === 'content_filter' || finish === 'safety') {
      throw new AiError('Gemini blocked this request (safety filter).');
    }
    return text;
  }
}

/** @param {'claude'|'gemini'} provider */
function createAi(provider, o) {
  return provider === 'claude' ? new ClaudeCommitAi(o) : new GeminiCommitAi(o);
}

module.exports = {
  AiError, ClaudeCommitAi, GeminiCommitAi, createAi, buildPrompt, clean, errorMessageFrom, SYSTEM_PROMPT,
};
