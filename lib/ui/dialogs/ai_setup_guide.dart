import 'package:flutter/material.dart';

import '../../state/app_settings.dart';
import '../actions.dart';
import '../common.dart';
import 'basic_dialogs.dart';

/// Step-by-step guide for setting up AI commit messages.
Future<void> showAiSetupGuide(BuildContext context, {AiProvider? initial}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _AiSetupGuide(
      initialTab: initial == AiProvider.claude ? 1 : 0,
    ),
  );
}

enum _Lang { vi, en }

class _AiSetupGuide extends StatefulWidget {
  const _AiSetupGuide({required this.initialTab});

  final int initialTab;

  @override
  State<_AiSetupGuide> createState() => _AiSetupGuideState();
}

class _AiSetupGuideState extends State<_AiSetupGuide> {
  late int _tab = widget.initialTab;
  _Lang _lang = _Lang.vi;

  String t(String vi, String en) => _lang == _Lang.vi ? vi : en;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AppDialog(
      title: t('Hướng dẫn setup AI Commit Message', 'AI Commit Message Setup Guide'),
      width: 760,
      height: (size.height * 0.85).clamp(420, 760),
      actions: [
        FilledButton(onPressed: () => Navigator.pop(context), child: Text(t('Đóng', 'Close'))),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            _tabButton(0, 'Google Gemini'),
            _tabButton(1, 'Anthropic Claude'),
            _tabButton(2, t('Sử dụng & xử lý lỗi', 'Usage & troubleshooting')),
            const Spacer(),
            SegmentedButton<_Lang>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
              ),
              segments: const [
                ButtonSegment(value: _Lang.vi, label: Text('Tiếng Việt')),
                ButtonSegment(value: _Lang.en, label: Text('English')),
              ],
              selected: {_lang},
              onSelectionChanged: (v) => setState(() => _lang = v.first),
            ),
          ]),
          const SizedBox(height: 8),
          const Divider(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 12, right: 8, bottom: 8),
              child: SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: switch (_tab) {
                    0 => _gemini(),
                    1 => _claude(),
                    _ => _usage(),
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabButton(int i, String label) => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: TextButton(
          style: TextButton.styleFrom(
            backgroundColor: _tab == i ? AppColors.selection : null,
            foregroundColor: _tab == i ? AppColors.text : AppColors.textDim,
          ),
          onPressed: () => setState(() => _tab = i),
          child: Text(label),
        ),
      );

  // ---------------------------------------------------------------------------
  // Content
  // ---------------------------------------------------------------------------

  List<Widget> _gemini() => [
        _intro(t(
          'Gemini có gói miễn phí, không cần thẻ thanh toán. Phù hợp để dùng thử hoặc dùng cá nhân.',
          'Gemini has a free tier that needs no payment card. Good for trying out or personal use.',
        )),
        _step(1, t('Tạo API key', 'Create an API key'), [
          _text(t(
            'Mở Google AI Studio, đăng nhập bằng tài khoản Google, bấm "Create API key" '
                '(chọn hoặc tạo một Google Cloud project nếu được hỏi), rồi copy key.',
            'Open Google AI Studio, sign in with your Google account, click "Create API key" '
                '(pick or create a Google Cloud project if asked), then copy the key.',
          )),
          _link(t('Mở trang lấy API key', 'Open the API key page'), 'https://aistudio.google.com/apikey'),
        ]),
        _step(2, t('Nhập vào app', 'Enter it in the app'), [
          _text(t(
            'Trong app: menu Git (☰) ▸ AI Commit Message Settings…, hoặc nút ⚙ trên ô commit message. '
                'Chọn "Google Gemini" và dán key vào ô API key.',
            'In the app: Git menu (☰) ▸ AI Commit Message Settings…, or the ⚙ button above the commit '
                'message box. Choose "Google Gemini" and paste the key into the API key field.',
          )),
        ]),
        _step(3, t('Chọn model', 'Choose a model'), [
          _text(t('Gõ tên model hoặc bấm một gợi ý. Có thể copy tên dưới đây:',
              'Type a model name or click a suggestion. You can copy the names below:')),
          _models([
            ('gemini-3.5-flash-lite', t('nhanh, quota miễn phí mỗi ngày thường cao hơn', 'fast, usually a larger free daily quota')),
            ('gemini-3.8-flash', t('message tốt hơn, quota miễn phí thấp hơn', 'better messages, smaller free quota')),
            ('gemini-2.5-flash-lite', t('thế hệ trước', 'previous generation')),
          ]),
        ]),
        _step(4, t('Kiểm tra và lưu', 'Test and save'), [
          _text(t('Bấm "Test Connection". Khi thấy "Connection OK" thì bấm "Save".',
              'Click "Test Connection". When it shows "Connection OK", click "Save".')),
        ]),
        _note(t(
          'Giới hạn gói miễn phí: tính theo số request/phút, token/phút và request/ngày cho mỗi project '
              '(không phải mỗi key), reset lúc 0h giờ Thái Bình Dương (~14–15h giờ Việt Nam). Google không '
              'công bố cố định các con số; xem giới hạn thực tế của bạn trong Google AI Studio. Mỗi lần bấm ✨ '
              'tốn 1 request.',
          'Free tier limits are counted per project (not per key) as requests/minute, tokens/minute and '
              'requests/day, resetting at midnight Pacific time. Google does not publish fixed numbers; see '
              'your actual limits in Google AI Studio. Each ✨ click uses one request.',
        )),
        _note(
          t(
            'Quyền riêng tư: ở gói miễn phí, Google có thể dùng dữ liệu gửi lên (diff code của bạn) để cải '
                'thiện sản phẩm. Gói trả phí thì không. Hãy kiểm tra quy định của công ty trước khi dùng với code nội bộ.',
            'Privacy: on the free tier Google may use what you send (your code diffs) to improve its products. '
                'The paid tier does not. Check your company policy before using it with private code.',
          ),
          warning: true,
        ),
      ];

  List<Widget> _claude() => [
        _intro(t(
          'Claude API tính phí theo token. Một commit message thường chỉ tốn rất ít, nhưng tài khoản cần có '
              'credit hoặc phương thức thanh toán.',
          'The Claude API is billed per token. A commit message usually costs very little, but the account '
              'needs credits or a payment method.',
        )),
        _step(1, t('Tạo tài khoản và nạp credit', 'Create an account and add credits'), [
          _text(t(
            'Đăng ký tại Claude Console, vào mục Billing để thêm phương thức thanh toán hoặc mua credit. '
                'Bạn có thể đặt giới hạn chi tiêu (spend limit) ở đó.',
            'Sign up at the Claude Console and open Billing to add a payment method or buy credits. '
                'You can also set a spend limit there.',
          )),
          _link(t('Mở Claude Console', 'Open the Claude Console'), 'https://platform.claude.com'),
        ]),
        _step(2, t('Tạo API key', 'Create an API key'), [
          _text(t(
            'Vào Settings ▸ API Keys ▸ Create Key, đặt tên rồi copy key ngay (key chỉ hiển thị một lần).',
            'Go to Settings ▸ API Keys ▸ Create Key, name it and copy the key right away (it is shown only once).',
          )),
          _link(t('Mở trang API Keys', 'Open the API Keys page'), 'https://platform.claude.com/settings/keys'),
        ]),
        _step(3, t('Nhập vào app', 'Enter it in the app'), [
          _text(t(
            'Menu Git (☰) ▸ AI Commit Message Settings…, chọn "Anthropic Claude" và dán key.',
            'Git menu (☰) ▸ AI Commit Message Settings…, choose "Anthropic Claude" and paste the key.',
          )),
        ]),
        _step(4, t('Chọn model', 'Choose a model'), [
          _models([
            ('claude-opus-5-5', t('chất lượng cao nhất', 'highest quality')),
            ('claude-sonnet-5-5', t('cân bằng giá và chất lượng', 'balance of cost and quality')),
            ('claude-haiku-5-5', t('rẻ và nhanh nhất', 'cheapest and fastest')),
          ]),
        ]),
        _step(5, t('Kiểm tra và lưu', 'Test and save'), [
          _text(t('Bấm "Test Connection", thấy "Connection OK" thì bấm "Save".',
              'Click "Test Connection"; when it shows "Connection OK", click "Save".')),
        ]),
      ];

  List<Widget> _usage() => [
        _step(1, t('Sinh commit message', 'Generate a message'), [
          _text(t(
            'Trong panel Commit, tick các file muốn commit rồi bấm ✨ phía trên ô commit message. '
                'Message hiện dần vào ô; bấm vào biểu tượng đang quay để dừng. Bạn có thể sửa message trước khi Commit.',
            'In the Commit panel, check the files to commit and click ✨ above the message box. '
                'The message streams into the box; click the spinning icon to stop. Edit it before committing if needed.',
          )),
          _text(t(
            'Khi tick "Amend", message được viết cho commit trước cộng với các thay đổi đang tick.',
            'With "Amend" checked, the message covers the previous commit plus the checked changes.',
          )),
        ]),
        _step(2, t('Tuỳ chỉnh', 'Customize'), [
          _text(t(
            '"Message language": ngôn ngữ của message (ví dụ English, Vietnamese). Để trống thì theo lịch sử commit của repo.\n'
                '"Extra instructions": quy ước riêng, ví dụ "Dùng Conventional Commits (feat:, fix:)" hoặc '
                '"Ghi mã Jira lấy từ tên branch".',
            '"Message language": the language of the message (e.g. English, Vietnamese). Empty follows the repository history.\n'
                '"Extra instructions": your own conventions, e.g. "Use Conventional Commits (feat:, fix:)" or '
                '"Mention the Jira ticket from the branch name".',
          )),
        ]),
        _step(3, t('Lỗi thường gặp', 'Common errors'), [
          _troubleRow(t('Sai API key / 401 / 403', 'Invalid API key / 401 / 403'),
              t('Copy lại key, kiểm tra không thừa khoảng trắng; với Claude kiểm tra tài khoản còn credit.',
                  'Copy the key again without extra spaces; for Claude check the account has credits.')),
          _troubleRow(t('Unknown model / 404', 'Unknown model / 404'),
              t('Tên model gõ sai hoặc model đã ngừng; bấm một gợi ý model trong Settings.',
                  'The model name is wrong or retired; click a suggested model in Settings.')),
          _troubleRow(t('Quota exceeded / 429', 'Quota exceeded / 429'),
              t('Hết giới hạn (thường là gói free Gemini). Chờ reset, hoặc đổi sang model khác như gemini-3.5-flash-lite.',
                  'Limit reached (usually the Gemini free tier). Wait for the reset or switch to another model such as gemini-3.5-flash-lite.')),
          _troubleRow(t('Network error', 'Network error'),
              t('Kiểm tra Internet, proxy hoặc firewall công ty có chặn api.anthropic.com / generativelanguage.googleapis.com không.',
                  'Check the Internet connection and whether a proxy or firewall blocks api.anthropic.com / generativelanguage.googleapis.com.')),
          _troubleRow(t('"Large diffs were left out"', '"Large diffs were left out"'),
              t('File có diff rất lớn (lockfile, file generate) chỉ được gửi tên. Có thể bỏ tick các file đó rồi sinh lại.',
                  'Files with huge diffs (lockfiles, generated files) are sent by name only. Uncheck them and generate again.')),
          _troubleRow(t('Xem chi tiết', 'More details'),
              t('Tab Console ở cửa sổ Git ghi lại model đã dùng và kích thước diff đã gửi.',
                  'The Console tab of the Git window logs the model used and the size of the diff sent.')),
        ]),
        _note(t(
          'API key được lưu dạng không mã hoá trong %APPDATA%\\git_tools\\settings.json trên máy này. '
              'Không chia sẻ file đó. Muốn xoá key: mở Settings, xoá ô API key hoặc chọn "Not configured" rồi Save.',
          'API keys are stored unencrypted in %APPDATA%\\git_tools\\settings.json on this computer. '
              'Do not share that file. To remove a key: open Settings, clear the API key or choose "Not configured", then Save.',
        )),
      ];

  // ---------------------------------------------------------------------------
  // Building blocks
  // ---------------------------------------------------------------------------

  Widget _intro(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Text(text, style: const TextStyle(fontSize: 13.5, height: 1.45)),
      );

  Widget _text(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: const TextStyle(fontSize: 13, height: 1.45, color: AppColors.textDim)),
      );

  Widget _step(int n, String title, List<Widget> body) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
              child: Text('$n',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 6),
                    child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  ...body,
                ],
              ),
            ),
          ],
        ),
      );

  Widget _link(String label, String url) => Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 6),
        child: Row(children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.open_in_new, size: 14),
            label: Text(label),
            onPressed: () => openUrl(url),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(url,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          ),
          ToolButton(
            icon: Icons.copy,
            tooltip: t('Copy link', 'Copy link'),
            size: 13,
            onPressed: () => copyToClipboard(context, url),
          ),
        ]),
      );

  Widget _models(List<(String, String)> models) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (id, desc) in models)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                InkWell(
                  onTap: () => copyToClipboard(context, id, label: t('Đã copy $id', 'Copied $id')),
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(id, style: monoStyle(size: 12.5)),
                      const SizedBox(width: 6),
                      const Icon(Icons.copy, size: 12, color: AppColors.textMuted),
                    ]),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(desc, style: const TextStyle(fontSize: 12.5, color: AppColors.textDim)),
                ),
              ]),
            ),
        ],
      );

  Widget _note(String text, {bool warning = false}) {
    final color = warning ? AppColors.warning : AppColors.accent;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(warning ? Icons.privacy_tip_outlined : Icons.info_outline, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5, height: 1.45))),
      ]),
    );
  }

  Widget _troubleRow(String problem, String fix) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 190,
            child: Text(problem, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Text(fix, style: const TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.textDim)),
          ),
        ]),
      );
}
