# Git Tools

Git client cho desktop viết bằng Flutter, mô phỏng Git tool window của Android Studio.
Ứng dụng gọi trực tiếp `git` CLI nên cần cài Git và có `git` trong PATH.

## Chạy

```bash
flutter run -d windows                 # hoặc macos / linux
flutter run -d windows -a "D:\path\repo"   # mở thẳng một repo
flutter build windows --release
```

## Tính năng

**Commit tool window (Alt+0)**
- Cây Changes / Unversioned Files / Merge Conflicts, tick checkbox để chọn file commit (không cần staging, giống AS)
- Click 1 lần mở diff dạng preview, double-click mở tab cố định; group theo thư mục
- Commit, Commit and Push…, Amend, Sign-off, đổi author (Ctrl+Enter để commit)
- Rollback (có tuỳ chọn xoá file added), Delete / Add to .gitignore cho file unversioned
- Show History, Annotate (git blame), Copy Path, Show in Explorer
- Banner Merging / Rebasing / Cherry-picking với Continue / Skip / Abort

**AI commit message (✨ cạnh ô commit message)**
- Sinh commit message từ diff của các file đã tick (khi Amend thì gồm cả thay đổi của commit trước),
  bám theo phong cách 15 commit gần nhất; message hiện dần vào ô, bấm lại để dừng
- Hỗ trợ **Anthropic Claude** (Messages API) và **Google Gemini** (endpoint tương thích OpenAI)
- Không có cấu hình mặc định: người dùng tự chọn provider, nhập API key và model trong
  Commit Options ▸ AI Commit Message Settings… (hoặc menu Git), có nút Test Connection
- Màn hình **AI Setup Guide** (menu Git, hoặc nút "Setup guide" trong dialog cài đặt): hướng dẫn từng bước
  lấy key Gemini / Claude, chọn model, giới hạn gói free, quyền riêng tư và xử lý lỗi; song ngữ Việt / Anh
- Tuỳ chọn ngôn ngữ message và hướng dẫn thêm (ví dụ Conventional Commits)
- Diff quá lớn (>40K ký tự/file hoặc >150K tổng) chỉ được liệt kê tên file và có thông báo
- Lưu ý: API key lưu dạng không mã hoá trong `%APPDATA%\git_tools\settings.json`;
  gói free của Gemini có giới hạn request/ngày và Google có thể dùng dữ liệu gửi lên để cải thiện sản phẩm

**Diff viewer**
- Side-by-side và Unified, highlight thay đổi trong dòng (word-level)
- Thu gọn vùng không đổi, Ignore whitespace, overview ruler, F7 / Shift+F7 để nhảy giữa các thay đổi
- Nút `»` để revert từng chunk về HEAD (với diff working tree)
- Xem ảnh hai bên cho file ảnh nhị phân

**Git tool window (Alt+9)**
- Log: cây branch (HEAD, Local, Remote, Tags), đồ thị commit có màu theo nhánh, ref labels,
  lọc theo text/hash/author, theo branch, theo file (Show History)
- Chi tiết commit: danh sách file đã đổi, message, author/committer, các branch chứa commit
- Menu commit: Cherry-Pick, Checkout Revision, Compare with Local, Reset (soft/mixed/hard/keep),
  Revert, Undo Commit, Edit Commit Message, Drop Commit, New Branch, New Tag
- Console: toàn bộ lệnh git đã chạy và output, có ô chạy lệnh git tuỳ ý
- Stashes: Pop / Apply / Drop / Clear / Unstash as Branch, xem file và diff trong stash

**Branches (Ctrl+Shift+`)**
- Popup giống AS: Update Project, Commit, Push, New Branch, Checkout Tag or Revision, danh sách Local/Remote
- Checkout (Smart Checkout tự stash/unstash khi có thay đổi cục bộ), New Branch from, Checkout and Rebase,
  Compare with current (commit hai phía + file khác nhau), Rebase onto, Merge into, Rename, Delete (local/remote)

**Remote**
- Update Project / Pull (Ctrl+T): Merge, Rebase hoặc Fast-forward only
- Push (Ctrl+Shift+K): xem trước commit sẽ push, force-with-lease, push tags, tự set upstream cho branch mới
- Fetch, Manage Remotes

**Conflicts**
- Dialog Conflicts: Accept Yours / Accept Theirs / Merge…
- Merge tool 3 cột (Ours | Result | Theirs): chọn từng conflict, Left+Right, Right+Left, Base, sửa tay

Ngoài ra: màn hình Welcome (Open / Clone / New Repository, repo gần đây), tự refresh khi file
hoặc `.git` thay đổi (kể cả thao tác git từ terminal bên ngoài), thông báo dạng toast.

## Cấu trúc

```
lib/
  git/          # tầng git: chạy lệnh, parse status/log/refs, diff engine, graph layout, conflict parser
  state/        # RepoController (state + thao tác), AppSettings (lưu ở %APPDATA%/git_tools)
  ui/           # commit/, diff/, log/, branches/, conflicts/, dialogs/, console/, workspace_page.dart
test/           # unit test diff/graph/conflict + test tích hợp chạy git thật trên repo tạm
```
