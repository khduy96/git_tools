# Git Tools (Android Studio style) — Hướng dẫn sử dụng

Extension cho VS Code mang Git tool window kiểu Android Studio vào VS Code:

- Panel **Commit**: tick chọn file để commit, không cần thao tác staging.
- **Log** có đồ thị nhánh.
- Popup **Branches**.
- Push / Update Project.
- Stash.
- Merge tool 3 cột.
- **AI tự viết commit message** bằng Claude hoặc Google Gemini.

Phiên bản: 0.1.0 · Yêu cầu: VS Code **1.90 trở lên** và **Git** đã cài (lệnh `git` chạy được trong terminal).

---

## Mục lục

1. [Cài đặt](#1-cài-đặt)
2. [Giao diện tổng quan](#2-giao-diện-tổng-quan)
3. [Commit](#3-commit)
4. [Xem diff](#4-xem-diff)
5. [Log và lịch sử commit](#5-log-và-lịch-sử-commit)
6. [Branches](#6-branches)
7. [Push, Update Project, Fetch](#7-push-update-project-fetch)
8. [Stash](#8-stash)
9. [Merge, rebase và giải quyết conflict](#9-merge-rebase-và-giải-quyết-conflict)
10. [AI commit message](#10-ai-commit-message)
11. [Cài đặt (Settings)](#11-cài-đặt-settings)
12. [Danh sách lệnh](#12-danh-sách-lệnh)
13. [Xử lý sự cố](#13-xử-lý-sự-cố)
14. [Giới hạn hiện tại](#14-giới-hạn-hiện-tại)
15. [Dành cho người phát triển](#15-dành-cho-người-phát-triển)

---

## 1. Cài đặt

### Cách 1 — Cài từ file `.vsix` (khuyên dùng)

File `git-tools-as-0.1.0.vsix` nằm trong thư mục extension.

**Trong VS Code:**
1. Mở view Extensions (`Ctrl+Shift+X`).
2. Bấm `…` ở góc trên view.
3. Chọn **Install from VSIX…** và chọn file `.vsix`.

**Hoặc bằng terminal:**

```bash
code --install-extension git-tools-as-0.1.0.vsix
```

Sau khi cài, nếu VS Code yêu cầu thì bấm **Reload**. Biểu tượng **Git Tools** sẽ xuất hiện trên thanh activity bar bên trái.

### Cách 2 — Chạy trực tiếp từ thư mục mã nguồn (không cần cài)

Extension viết bằng JavaScript thuần, không cần `npm install` hay build:

```bash
code --extensionDevelopmentPath="<đường-dẫn>/extrensions/git_tools" "<thư-mục-repo-của-bạn>"
```

Lệnh trên mở một cửa sổ VS Code có tiêu đề `[Extension Development Host]` với extension đã được nạp.

### Gỡ cài đặt

Vào view Extensions, chọn **Git Tools (Android Studio style)** rồi bấm **Uninstall**. Hoặc dùng terminal:

```bash
code --uninstall-extension local.git-tools-as
```

> Workspace phải được **tin cậy** (Workspace Trust). Ở Restricted Mode, VS Code tắt extension này, cũng như tắt Git tích hợp.

---

## 2. Giao diện tổng quan

| Vị trí | Thành phần | Tương ứng Android Studio |
|---|---|---|
| Activity bar ▸ **Git Tools** ▸ **Commit** | Danh sách thay đổi, ô commit message, nút Commit | Commit tool window (Alt+0) |
| Activity bar ▸ **Git Tools** ▸ **Branches** | HEAD, Local, Remote, Tags, Stashes | Cây branch trong Git tool window |
| Panel dưới ▸ **Git Tools** ▸ **Log** | Lịch sử commit có đồ thị nhánh | Git ▸ Log (Alt+9) |
| Thanh trạng thái, góc trái: `⑂ main 2↑ 1↓` | Branch hiện tại, số commit chưa push ↑ và chưa pull ↓. Bấm vào để mở popup Branches | Branch widget |
| Output ▸ **Git Tools** | Mọi lệnh git đã chạy kèm kết quả | Tab Console |

**Mở Log:**
- Command Palette (`Ctrl+Shift+P`) ▸ **Git Tools: Show Git Log**; hoặc
- Menu **View ▸ Open View… ▸ Log**; hoặc
- Bấm một branch trong cây Branches.

**Nhiều repository trong một workspace:** extension tự chọn repo chứa file đang mở. Muốn đổi tay thì dùng **Git Tools: Select Repository…** (hoặc `…` trên view Commit). Lệnh này cũng mở được một thư mục repo nằm ngoài workspace.

Dữ liệu tự làm mới khi file hoặc thư mục `.git` thay đổi (kể cả khi bạn chạy git từ terminal) và khi cửa sổ VS Code được focus lại. Làm mới thủ công bằng nút ⟳ trên view.

---

## 3. Commit

View **Commit** có các nhóm:

- **Merge Conflicts** — chỉ xuất hiện khi có conflict. Link **Resolve** mở công cụ giải quyết conflict.
- **Changes** — file đã được git theo dõi và có thay đổi. **Mặc định được tick.**
- **Unversioned Files** — file mới chưa được theo dõi. **Mặc định không tick.**

Chỉ các file **được tick** mới được commit. Bạn không cần stage: extension tự `git add` và commit đúng các file đã chọn, giống Android Studio.

### Thao tác

| Thao tác | Cách làm |
|---|---|
| Xem diff một file | Click file (mở dạng preview tab). Double-click hoặc `Enter` để mở tab cố định |
| Chọn nhiều file | `Ctrl+Click`, `Shift+Click`, `Ctrl+A` |
| Tick / bỏ tick | Checkbox, hoặc `Space` cho các file đang chọn. Checkbox ở dòng nhóm áp dụng cho cả nhóm |
| Di chuyển | `↑` / `↓` |
| Rollback file đang chọn | `Delete`, hoặc chuột phải ▸ **Rollback…** |
| Commit | Nút **Commit** hoặc `Ctrl+Enter` trong ô message |
| Commit rồi push | **Commit and Push…** |
| Sửa commit trước | Tick **Amend**. Nếu ô message đang trống, message cũ được điền sẵn |

### Menu chuột phải trên file

- Show Diff
- Open File
- Resolve Conflicts…
- Include in Commit / Exclude from Commit
- Rollback… — đưa file về trạng thái HEAD. Với file mới thêm, bạn được chọn giữ hay xoá bản trên đĩa.
- Delete… và Add to .gitignore — chỉ có với file chưa được theo dõi.
- Show History — mở Log lọc theo file.
- Copy Path
- Reveal in Explorer View

### Thanh tiêu đề view Commit

- **✨** — sinh commit message bằng AI (xem [mục 10](#10-ai-commit-message)).
- **Stash Changes…**
- **⟳ Refresh**
- Trong menu `…`:
  - Update Project
  - Push
  - Fetch
  - Select Repository
  - AI Commit Message: Configure / Setup Guide

---

## 4. Xem diff

Diff dùng trình so sánh có sẵn của VS Code, nên có đủ side-by-side / inline, điều hướng thay đổi và các tính năng khác của VS Code.

- **Diff working tree** có tiêu đề `file (HEAD ↔ Working Tree)`. Bên phải là file thật, sửa trực tiếp được; bạn cũng có thể dùng nút revert từng đoạn của VS Code.
- **Diff trong commit** có tiêu đề `file (parent ↔ commit)`.
- File mới hiện bên trái rỗng; file bị xoá hiện bên phải rỗng.

---

## 5. Log và lịch sử commit

View **Log** gồm 3 phần:

1. **Thanh lọc:**
   - Ô tìm kiếm — lọc ngay theo nội dung message, hash, tác giả, email hoặc tên ref.
   - Dropdown **Branch** — All, HEAD hoặc một branch cụ thể.
   - Chip **Path** khi đang xem lịch sử một file. Bấm `×` để bỏ lọc.
2. **Bảng commit:**
   - Đồ thị nhánh có màu.
   - Nhãn ref màu: HEAD vàng, branch local xanh lá, remote tím, tag xanh dương.
   - Các cột message, tác giả, thời gian, hash.
   - Commit HEAD được in đậm.
   - Khi đang lọc bằng ô tìm kiếm, đồ thị được ẩn đi.
3. **Chi tiết commit** (bên phải, kéo thanh chia để đổi độ rộng):
   - Danh sách file thay đổi. Click để xem diff; với merge commit thì so với parent đầu tiên.
   - Message đầy đủ, tác giả, committer, parent.
   - Các branch chứa commit.

**Phím tắt trong bảng:**
- `↑` / `↓`, `PageUp` / `PageDown` — di chuyển.
- `Ctrl+Click` / `Shift+Click` — chọn nhiều commit.
- `Ctrl+Alt+Shift+C` — copy hash.

### Menu chuột phải trên commit

| Lệnh | Ý nghĩa |
|---|---|
| Copy Revision Number | Copy hash (nhiều commit thì cách nhau bằng dấu cách) |
| Cherry-Pick | Áp dụng commit đã chọn vào branch hiện tại, theo thứ tự cũ đến mới |
| Checkout Revision | Checkout commit (detached HEAD) |
| Compare with Local | Liệt kê commit hai phía và các file khác nhau giữa commit đó và HEAD |
| Reset Current Branch to Here… | Chọn chế độ **Soft / Mixed / Hard / Keep**. Hard hỏi xác nhận lại |
| Revert Commit | Tạo commit đảo ngược |
| Undo Commit… | Chỉ với commit HEAD. Huỷ commit nhưng giữ thay đổi trong working tree |
| Edit Commit Message… | Chỉ với commit HEAD |
| Drop Commit | Xoá commit khỏi lịch sử branch hiện tại (rebase) |
| New Branch… / New Tag… | Tạo branch hoặc tag tại commit đó |

### Menu chuột phải trên file trong chi tiết commit

- Show Diff
- Compare with Local
- Show History for File
- Get from Revision — lấy nội dung file ở commit đó ghi đè vào working tree.
- Copy Path

**Xem lịch sử một file:** chuột phải tab editor ▸ **Show History for Current File**, hoặc lệnh **Git Tools: Show History for Current File**.

---

## 6. Branches

### Popup Branches

Bấm branch trên thanh trạng thái hoặc chạy lệnh **Git Tools: Branches…**. Popup gồm:

- Hành động nhanh: Update Project, Commit, Push, New Branch, Checkout Tag or Revision.
- Danh sách **Local** và **Remote**:
  - Branch hiện tại xếp đầu.
  - `main` / `master` / `develop` được đánh dấu ★.
  - Mỗi branch hiện số ↑ / ↓ và upstream.
- Gõ để tìm branch. Chọn một branch sẽ mở danh sách thao tác.

### Thao tác trên branch

Dùng trong popup hoặc khi chuột phải trong cây Branches:

| Lệnh | Ghi chú |
|---|---|
| Checkout | Branch remote: tự checkout branch local cùng tên nếu đã có, nếu chưa thì tạo branch local tracking |
| New Branch from '…' | Tạo branch mới từ branch hoặc tag đó, có thể checkout luôn |
| Checkout and Rebase onto Current | Checkout branch đó và rebase nó lên branch hiện tại |
| Compare with Current | Commit hai phía và các file khác nhau. Chọn file để xem diff |
| Show in Log | Lọc Log theo branch |
| Rebase Current onto This / Merge into Current | Có thể phát sinh conflict, xem [mục 9](#9-merge-rebase-và-giải-quyết-conflict) |
| Update (fast-forward) | Cập nhật branch local từ upstream mà không cần checkout |
| Push… | Chỉ với branch hiện tại |
| Rename… / Copy Branch Name | |
| Delete | Branch chưa merge sẽ hỏi lại trước khi xoá hẳn. Branch remote sẽ đẩy lệnh xoá lên remote |

**Smart Checkout:** nếu checkout bị chặn vì thay đổi chưa commit sẽ bị ghi đè, extension đề nghị **Smart Checkout**: stash thay đổi, checkout, rồi trả lại thay đổi.

Trong cây Branches còn có:
- Mục **Tags**: Checkout, New Branch, Merge, Push Tag, Delete Tag.
- Mục **Stashes**: xem [mục 8](#8-stash).

---

## 7. Push, Update Project, Fetch

**Push…** (lệnh **Git Tools: Push…**):
- Hiện danh sách commit sẽ được push và đích đến `remote/branch`. Đích là branch mới thì có ghi `(new)`.
- Các lựa chọn:
  - **Push**.
  - **Force Push** — dùng `--force-with-lease` và hỏi xác nhận.
  - **Push with tags**.
  - **Change remote or target branch…**
- Branch chưa có upstream sẽ được tự đặt upstream (`--set-upstream`).

**Update Project / Pull…** (lệnh **Git Tools: Update Project / Pull…**):
- Chọn **Merge**, **Rebase** hoặc **Fast-forward only**. Lựa chọn lần trước được ghi nhớ.
- Lấy từ upstream của branch. Nếu branch chưa có upstream, extension hỏi bạn chọn branch remote.

**Fetch:** chạy `git fetch --all --prune`.

Khi Git cần đăng nhập, Git Credential Manager tự hiện cửa sổ đăng nhập. Extension không hỏi mật khẩu trong terminal.

---

## 8. Stash

- **Tạo stash:** nút Stash trên view Commit, hoặc lệnh **Git Tools: Stash Changes…**. Nhập message, rồi chọn có kèm file chưa theo dõi (*Include unversioned files*) và/hoặc *Keep index* hay không.
- **Dùng stash:** cây Branches ▸ **Stashes**, chuột phải một stash:
  - **Pop** — áp dụng rồi xoá stash.
  - **Apply** — áp dụng, giữ lại stash.
  - **Show Changes** — xem danh sách file và diff.
  - **Unstash as Branch…**
  - **Drop**

---

## 9. Merge, rebase và giải quyết conflict

Khi đang merge / rebase / cherry-pick / revert, view Commit hiện banner kiểu **"Merging in progress · 1 conflict"** kèm nút:

- **Resolve…** khi còn conflict.
- **Continue** khi đã giải quyết hết. Với merge, Continue tạo merge commit bằng message mặc định của git.
- **Abort**.

Trong lúc merge, ô message được điền sẵn message mặc định của git (`Merge branch '…'`). Bạn sửa message rồi bấm **Commit** cũng được.

### Giải quyết conflict

Mở bằng link **Resolve** ở nhóm Merge Conflicts, hoặc lệnh **Git Tools: Resolve Conflicts…**. Chọn file, sau đó chọn:

- **Merge…** — mở **merge tool 3 cột**:
  - Bên trái: **Yours** (branch hiện tại). Ở giữa: **Result**. Bên phải: **Theirs** (bên được merge vào).
  - Với mỗi đoạn conflict:
    - Bấm **»** để lấy bên trái, **«** để lấy bên phải.
    - Hoặc chọn **Left + Right**, **Right + Left**, **Base** (nếu có), hay **Edit…** để tự sửa.
    - Bấm **Undo** để chọn lại.
  - **Accept Left / Accept Right** áp dụng cho mọi đoạn chưa xử lý. **Next Conflict** nhảy tới đoạn tiếp theo.
  - **Apply** chỉ bấm được khi đã xử lý hết. Bấm Apply sẽ ghi file và đánh dấu đã giải quyết (`git add`).
- **Accept Yours / Accept Theirs** — lấy nguyên một phía cho cả file. Dùng được cả khi một phía đã xoá file.
- **Open in Editor** — sửa marker trực tiếp trong editor, sau đó chọn **Mark as Resolved**.

> Khi **rebase**, git đảo vai trò hai phía: bên trái là *Upstream* (branch bạn đang rebase lên), bên phải là *Your commit*. Merge tool ghi rõ nhãn này.

---

## 10. AI commit message

Nút **✨** viết commit message từ diff của các file đang tick. Message hiện dần vào ô commit; bấm **■** để dừng. Message cũ được giữ lại nếu bạn dừng hoặc có lỗi.

**Mặc định tính năng này chưa được cấu hình.** Mỗi người phải tự chọn dịch vụ và dùng API key của chính mình.

### Cấu hình nhanh

1. Chạy lệnh **Git Tools: AI Commit Message: Configure…**
2. Chọn dịch vụ:
   - **Google Gemini** — có gói miễn phí.
   - **Anthropic Claude** — trả phí theo token.
3. Chọn model gợi ý hoặc gõ tên model:
   - Gemini: `gemini-3.5-flash-lite` (nhanh, quota miễn phí thường cao hơn), `gemini-3.8-flash`.
   - Claude: `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`.
4. Dán API key:
   - Gemini: lấy tại https://aistudio.google.com/apikey
   - Claude: lấy tại https://platform.claude.com/settings/keys (tài khoản cần có credit).
5. Extension tự chạy **Test Connection**. Thấy thông báo "AI commit message is ready" là xong.

Hướng dẫn chi tiết từng bước (tiếng Việt / English) có trong lệnh **Git Tools: AI Commit Message: Setup Guide**.

### Cách hoạt động

- Gửi diff của các file **đang tick**. Nếu đang tick **Amend** thì gửi thêm thay đổi của commit trước.
- Gửi kèm 15 commit gần nhất để AI viết theo đúng phong cách của repo (prefix `feat:` / `fix:`, cách viết hoa, ngôn ngữ).
- File có diff quá lớn (hơn 40.000 ký tự mỗi file, hoặc tổng hơn 150.000 ký tự) chỉ được gửi tên file, và bạn sẽ nhận được thông báo.
- Nút ✨ cũng có trên thanh tiêu đề **Source Control** có sẵn của VS Code. Khi bấm từ đó, message được ghi vào ô commit của VS Code, nhưng vẫn dựa trên các file đang tick trong view Commit của Git Tools.

### Tuỳ chỉnh

Vào Settings, tìm `gitTools.ai`:
- `Ai: Language` — ngôn ngữ của message, ví dụ `English`, `Vietnamese`. Để trống thì AI theo lịch sử commit của repo.
- `Ai: Instructions` — quy ước riêng, ví dụ `Use Conventional Commits`, hoặc `Ghi mã Jira lấy từ tên branch`.

### API key và quyền riêng tư

- API key được lưu trong **Secret Storage** của VS Code: được mã hoá bằng kho mật khẩu của hệ điều hành, không nằm trong `settings.json` và không đồng bộ qua Settings Sync.
- Đổi key: **AI Commit Message: Set API Key…**. Xoá key: **AI Commit Message: Remove API Key…**. Tắt tính năng: Configure ▸ **Not configured**.
- **Gói miễn phí của Gemini:**
  - Có giới hạn số request mỗi phút và mỗi ngày, tính theo project. Mỗi lần bấm ✨ tốn 1 request. Xem giới hạn thực tế của bạn trong Google AI Studio.
  - Google **có thể dùng dữ liệu gửi lên (diff code) để cải thiện sản phẩm**. Gói trả phí thì không.
  - Hãy kiểm tra quy định của công ty trước khi dùng với code nội bộ.

---

## 11. Cài đặt (Settings)

| Setting | Mặc định | Mô tả |
|---|---|---|
| `gitTools.gitPath` | `git` | Đường dẫn tới git |
| `gitTools.log.maxCommits` | `2000` | Số commit tối đa tải vào Log |
| `gitTools.autoRefresh` | `true` | Tự làm mới khi file hoặc `.git` thay đổi (cần reload window sau khi đổi) |
| `gitTools.ai.provider` | `none` | `none` / `claude` / `gemini` |
| `gitTools.ai.claudeModel` | *(trống)* | Model Claude |
| `gitTools.ai.geminiModel` | *(trống)* | Model Gemini |
| `gitTools.ai.language` | *(trống)* | Ngôn ngữ của commit message |
| `gitTools.ai.instructions` | *(trống)* | Hướng dẫn thêm cho AI |

---

## 12. Danh sách lệnh

Mở Command Palette (`Ctrl+Shift+P`) và gõ `Git Tools`:

| Lệnh | Chức năng |
|---|---|
| Commit… | Mở view Commit và focus vào ô message |
| Push… / Update Project / Pull… / Fetch | Đồng bộ với remote |
| Branches… / New Branch… / Checkout Tag or Revision… | Quản lý branch |
| Stash Changes… | Tạo stash |
| Resolve Conflicts… / Continue Merge / Rebase / Abort Merge / Rebase | Xử lý merge, rebase |
| Show Git Log / Show History for Current File | Xem lịch sử |
| Manage Remotes… | Thêm, sửa URL, xoá remote |
| Select Repository… | Chọn repo khi có nhiều repo |
| Show Git Console | Xem các lệnh git đã chạy |
| Refresh | Làm mới |
| AI Commit Message: Configure… / Set API Key… / Remove API Key… / Test Connection / Setup Guide | Cấu hình AI |
| Generate Commit Message | Sinh message (giống nút ✨) |

Extension không gán phím tắt mặc định để tránh trùng phím của VS Code. Muốn gán phím tắt kiểu Android Studio thì vào **File ▸ Preferences ▸ Keyboard Shortcuts** và tìm `gitTools`. Ví dụ: `gitTools.focusCommit`, `gitTools.push`, `gitTools.update`, `gitTools.branches`.

---

## 13. Xử lý sự cố

| Hiện tượng | Cách xử lý |
|---|---|
| View Commit báo "No Git repository found" | Mở đúng thư mục repo, hoặc dùng **Select Repository…** ▸ *Open Repository Folder…*. Kiểm tra `git` chạy được trong terminal, hoặc đặt `gitTools.gitPath` |
| Không thấy biểu tượng Git Tools | Kiểm tra extension đã bật trong view Extensions và workspace đã được tin cậy (Workspace Trust) |
| Thao tác git báo lỗi | Bấm **Show Console** trên thông báo lỗi, hoặc chạy **Show Git Console**, để xem lệnh và output đầy đủ |
| Push / Fetch bị treo hoặc lỗi xác thực | Đăng nhập lại qua Git Credential Manager, hoặc kiểm tra SSH key. Extension tắt việc hỏi mật khẩu trong terminal |
| AI: *Invalid API key / 401 / 403* | Chạy **Set API Key…** và dán lại key. Với Claude, kiểm tra tài khoản còn credit |
| AI: *Unknown model / 404* | Chạy lại **Configure…** và chọn model gợi ý |
| AI: *Quota exceeded / 429* | Hết giới hạn (thường là gói free của Gemini). Chờ reset hoặc đổi model |
| AI: *Network error* | Kiểm tra proxy / firewall có chặn `api.anthropic.com` hoặc `generativelanguage.googleapis.com` không |
| Dữ liệu không tự cập nhật | Bấm ⟳. Kiểm tra `gitTools.autoRefresh` |

---

## 14. Giới hạn hiện tại

- Chưa có interactive rebase (squash / reorder nhiều commit), shelve, và stage từng dòng.
- Diff khi click file trong view Commit luôn so với `HEAD`, không tách riêng phần đã stage và chưa stage.
- Nút ✨ trên Source Control của VS Code dùng danh sách file đang tick của Git Tools, không dùng danh sách *Staged Changes* của VS Code.
- API key lưu riêng trên từng máy, không đồng bộ.

---

## 15. Dành cho người phát triển

```
git_tools/
├─ package.json         khai báo view, lệnh, menu, settings
├─ src/
│  ├─ extension.js      kích hoạt, đăng ký lệnh
│  ├─ git.js            chạy git và phân tích output (status, log, branch…)
│  ├─ model.js          trạng thái repo, tự làm mới, nhiều repo
│  ├─ graph.js          xếp làn cho đồ thị commit
│  ├─ commands.js       branch / push / pull / stash / reset / conflict…
│  ├─ commitView.js     view Commit        (media/commit.*)
│  ├─ logView.js        view Log           (media/log.*)
│  ├─ branchesTree.js   cây Branches + thanh trạng thái
│  ├─ mergeTool.js      merge tool 3 cột   (media/merge.*)
│  ├─ conflicts.js      đọc conflict marker
│  ├─ diff.js           nội dung file theo revision cho diff editor
│  ├─ ai.js             gọi Claude / Gemini (streaming)
│  ├─ aiCommands.js     cấu hình AI, Secret Storage, sinh message
│  └─ guide.js          trang Setup Guide  (media/guide.*)
└─ test/core.test.js    test không cần VS Code
```

- Không có dependency và không có bước build. Sửa file JS rồi reload cửa sổ Extension Development Host là thấy thay đổi.
- Chạy test (cần Node 18 trở lên và git):

  ```bash
  node --test test/core.test.js
  ```

- Đóng gói lại file `.vsix` (cần Node và Internet ở lần chạy đầu):

  ```bash
  npx @vscode/vsce package --allow-missing-repository --skip-license
  ```
