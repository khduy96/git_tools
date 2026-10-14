// AI commit message setup guide (Vietnamese / English).
(() => {
  const vscode = acquireVsCodeApi();
  const { h } = gt;
  const app = document.getElementById('app');
  const saved = vscode.getState() || {};
  let lang = saved.lang || 'vi';
  let tab = saved.tab || 'gemini';
  const post = (type, d = {}) => vscode.postMessage({ type, ...d });
  const t = (vi, en) => (lang === 'vi' ? vi : en);

  window.addEventListener('message', (e) => {
    if (e.data.type === 'tab') {
      tab = e.data.tab;
      render();
    }
  });

  const text = (s) => h('p', { text: s });
  const link = (label, url) => h('div.linkrow', null,
    h('button.secondary', { text: `↗ ${label}`, onclick: () => post('openUrl', { url }) }),
    h('span.muted', { text: url }));
  const action = (label, command) => h('button', { text: label, onclick: () => post('command', { command }) });
  const step = (n, title, ...body) => h('div.step', null, h('div.num', { text: String(n) }),
    h('div.content', null, h('h3', { text: title }), ...body));
  const note = (s, warn) => h(`div.note${warn ? '.warn' : ''}`, { text: s });
  const models = (list) => h('div.models', null, list.map(([id, desc]) => h('div.model', null,
    h('code', { text: id, title: t('Bấm để copy', 'Click to copy'), onclick: () => post('copy', { text: id }) }),
    h('span.muted', { text: desc }))));
  const kbd = (s) => h('code', { text: s });

  function gemini() {
    return [
      h('p.intro', { text: t(
        'Gemini có gói miễn phí, không cần thẻ thanh toán. Phù hợp để dùng thử hoặc dùng cá nhân.',
        'Gemini has a free tier that needs no payment card. Good for trying out or personal use.') }),
      step(1, t('Tạo API key', 'Create an API key'),
        text(t('Mở Google AI Studio, đăng nhập tài khoản Google, bấm "Create API key" (chọn hoặc tạo một Google Cloud project nếu được hỏi), rồi copy key.',
          'Open Google AI Studio, sign in with your Google account, click "Create API key" (pick or create a Google Cloud project if asked), then copy the key.')),
        link(t('Mở trang lấy API key', 'Open the API key page'), 'https://aistudio.google.com/apikey')),
      step(2, t('Cấu hình trong VS Code', 'Configure VS Code'),
        h('p', null, t('Chạy lệnh ', 'Run '), kbd('Git Tools: AI Commit Message: Configure…'),
          t(' (Ctrl+Shift+P), chọn "Google Gemini", chọn model, dán key. Key được lưu trong Secret Storage của VS Code (mã hoá).',
            ' (Ctrl+Shift+P), choose "Google Gemini", pick a model and paste the key. The key is stored encrypted in VS Code Secret Storage.')),
        action(t('Mở Configure…', 'Run Configure…'), 'gitTools.ai.configure')),
      step(3, t('Chọn model', 'Choose a model'),
        text(t('Chọn một gợi ý hoặc gõ tên model khác:', 'Pick a suggestion or type another model id:')),
        models([
          ['gemini-3.5-flash-lite', t('nhanh, quota miễn phí mỗi ngày thường cao hơn', 'fast, usually a larger free daily quota')],
          ['gemini-3.8-flash', t('message tốt hơn, quota miễn phí thấp hơn', 'better messages, smaller free quota')],
          ['gemini-2.5-flash-lite', t('thế hệ trước', 'previous generation')],
        ])),
      step(4, t('Kiểm tra', 'Test'),
        text(t('Configure tự chạy Test Connection ở bước cuối. Có thể chạy lại bất kỳ lúc nào:', 'Configure runs a connection test at the end. You can run it again any time:')),
        action('Test Connection', 'gitTools.ai.testConnection')),
      note(t(
        'Giới hạn gói miễn phí: tính theo request/phút, token/phút và request/ngày cho mỗi project (không phải mỗi key), reset lúc 0h giờ Thái Bình Dương (~14–15h giờ Việt Nam). Google không công bố cố định con số; xem giới hạn thực tế trong Google AI Studio. Mỗi lần sinh message tốn 1 request.',
        'Free tier limits are per project (not per key): requests/minute, tokens/minute and requests/day, resetting at midnight Pacific time. Google does not publish fixed numbers; check your actual limits in Google AI Studio. Each generated message uses one request.')),
      note(t(
        'Quyền riêng tư: ở gói miễn phí, Google có thể dùng dữ liệu gửi lên (diff code của bạn) để cải thiện sản phẩm; gói trả phí thì không. Kiểm tra quy định của công ty trước khi dùng với code nội bộ.',
        'Privacy: on the free tier Google may use what you send (your code diffs) to improve its products; the paid tier does not. Check your company policy before using it with private code.'), true),
    ];
  }

  function claude() {
    return [
      h('p.intro', { text: t(
        'Claude API tính phí theo token. Mỗi commit message thường tốn rất ít, nhưng tài khoản cần có credit hoặc phương thức thanh toán.',
        'The Claude API is billed per token. A commit message usually costs very little, but the account needs credits or a payment method.') }),
      step(1, t('Tạo tài khoản và nạp credit', 'Create an account and add credits'),
        text(t('Đăng ký tại Claude Console, vào Billing để thêm phương thức thanh toán hoặc mua credit. Có thể đặt giới hạn chi tiêu ở đó.',
          'Sign up at the Claude Console and open Billing to add a payment method or buy credits. You can also set a spend limit there.')),
        link(t('Mở Claude Console', 'Open the Claude Console'), 'https://platform.claude.com')),
      step(2, t('Tạo API key', 'Create an API key'),
        text(t('Vào Settings ▸ API Keys ▸ Create Key, đặt tên rồi copy key ngay (key chỉ hiển thị một lần).',
          'Go to Settings ▸ API Keys ▸ Create Key, name it and copy the key right away (it is shown only once).')),
        link(t('Mở trang API Keys', 'Open the API Keys page'), 'https://platform.claude.com/settings/keys')),
      step(3, t('Cấu hình trong VS Code', 'Configure VS Code'),
        h('p', null, t('Chạy ', 'Run '), kbd('Git Tools: AI Commit Message: Configure…'), t(', chọn "Anthropic Claude", chọn model, dán key.', ', choose "Anthropic Claude", pick a model and paste the key.')),
        action(t('Mở Configure…', 'Run Configure…'), 'gitTools.ai.configure')),
      step(4, t('Chọn model', 'Choose a model'),
        models([
          ['claude-opus-5-5', t('chất lượng cao nhất', 'highest quality')],
          ['claude-sonnet-5-5', t('cân bằng giá và chất lượng', 'balance of cost and quality')],
          ['claude-haiku-5-5', t('rẻ và nhanh nhất', 'cheapest and fastest')],
        ])),
      step(5, t('Kiểm tra', 'Test'), action('Test Connection', 'gitTools.ai.testConnection')),
    ];
  }

  function usage() {
    const row = (p, f) => h('tr', null, h('td', { text: p }), h('td', { text: f }));
    return [
      step(1, t('Sinh commit message', 'Generate a message'),
        text(t('Trong view Commit (thanh bên Git Tools), tick các file muốn commit rồi bấm ✨ (trên thanh tiêu đề view hoặc cạnh ô message). Message hiện dần vào ô; bấm ■ để dừng. Có thể sửa message trước khi Commit.',
          'In the Commit view (Git Tools side bar), check the files to commit and click ✨ (view title bar or next to the message box). The message streams in; click ■ to stop. Edit it before committing if needed.')),
        text(t('Nút ✨ cũng có trên thanh tiêu đề Source Control có sẵn của VS Code: message được ghi vào ô commit của VS Code, dựa trên các file đang tick trong view Commit của Git Tools.',
          'The ✨ button is also on the title bar of VS Code\'s built-in Source Control view: the message goes into its commit box and is based on the files checked in the Git Tools Commit view.')),
        text(t('Khi tick "Amend", message được viết cho commit trước cộng các thay đổi đang tick.', 'With "Amend" checked, the message covers the previous commit plus the checked changes.'))),
      step(2, t('Tuỳ chỉnh', 'Customize'),
        text(t('Settings ▸ Git Tools: "Ai: Language" (ngôn ngữ message, để trống thì theo lịch sử repo) và "Ai: Instructions" (ví dụ "Dùng Conventional Commits").',
          'Settings ▸ Git Tools: "Ai: Language" (message language, empty follows the repository history) and "Ai: Instructions" (e.g. "Use Conventional Commits").')),
        h('button.secondary', { text: t('Mở Settings', 'Open Settings'), onclick: () => post('settings') })),
      step(3, t('Lỗi thường gặp', 'Common errors'),
        h('table', null,
          row(t('Sai API key / 401 / 403', 'Invalid API key / 401 / 403'), t('Chạy "Set API Key…" và dán lại key; với Claude kiểm tra tài khoản còn credit.', 'Run "Set API Key…" and paste the key again; for Claude check the account has credits.')),
          row(t('Unknown model / 404', 'Unknown model / 404'), t('Tên model sai hoặc đã ngừng; chạy lại Configure và chọn một gợi ý.', 'The model id is wrong or retired; run Configure again and pick a suggestion.')),
          row(t('Quota exceeded / 429', 'Quota exceeded / 429'), t('Hết giới hạn (thường là gói free Gemini). Chờ reset hoặc đổi model, ví dụ gemini-3.5-flash-lite.', 'Limit reached (usually the Gemini free tier). Wait for the reset or switch model, e.g. gemini-3.5-flash-lite.')),
          row(t('Network error', 'Network error'), t('Kiểm tra Internet, proxy/firewall có chặn api.anthropic.com hoặc generativelanguage.googleapis.com không.', 'Check the Internet connection and whether a proxy or firewall blocks api.anthropic.com or generativelanguage.googleapis.com.')),
          row(t('"Large diffs were left out"', '"Large diffs were left out"'), t('File có diff rất lớn (lockfile, file generate) chỉ được gửi tên. Bỏ tick các file đó rồi sinh lại.', 'Files with huge diffs (lockfiles, generated files) are sent by name only. Uncheck them and generate again.')),
          row(t('Xem chi tiết', 'More details'), t('Lệnh "Git Tools: Show Git Console" ghi lại model đã dùng và kích thước diff đã gửi.', '"Git Tools: Show Git Console" logs the model used and the size of the diff sent.')))),
      note(t('API key nằm trong Secret Storage của VS Code trên máy này, không nằm trong settings.json. Xoá bằng lệnh "AI Commit Message: Remove API Key…".',
        'API keys live in VS Code Secret Storage on this computer, not in settings.json. Remove them with "AI Commit Message: Remove API Key…".')),
    ];
  }

  function render() {
    vscode.setState({ lang, tab });
    const tabBtn = (id, label) => h(`button.tab${tab === id ? '.active' : ''}`, { text: label, onclick: () => { tab = id; render(); } });
    const langBtn = (id, label) => h(`button.lang${lang === id ? '.active' : ''}`, { text: label, onclick: () => { lang = id; render(); } });
    app.replaceChildren(
      h('h2', { text: t('Hướng dẫn setup AI Commit Message', 'AI Commit Message Setup Guide') }),
      h('div.tabs', null,
        tabBtn('gemini', 'Google Gemini'),
        tabBtn('claude', 'Anthropic Claude'),
        tabBtn('usage', t('Sử dụng & xử lý lỗi', 'Usage & troubleshooting')),
        h('span.spacer'),
        langBtn('vi', 'Tiếng Việt'),
        langBtn('en', 'English')),
      h('div.page', null, ...(tab === 'gemini' ? gemini() : tab === 'claude' ? claude() : usage())),
    );
  }

  render();
  post('ready');
})();
