# Source publication checklist / 源码公开前核对

The publication candidate consists of the application/core sources, tests, build scripts, original branding, the two READMEs, LICENSE/NOTICE, public docs, and benchmark text/code/sanitized results.

## Excluded local files

`.gitignore` excludes `.build/`, `dist/`, logs, private `.local/` notes, AI handoff prompts, the original implementation plan, old local verification notes, copied vendor references, generated benchmark audio/local runs, and common credential/signing-file extensions.

The old development notes include local filesystem paths and account/device context. They remain on the owner's Mac, outside the intended source publication. Copied vendor documents are also excluded rather than implicitly placed under this project's license.

**An ignore file only affects normal Git tracking.** It does not sanitize a manually uploaded ZIP, an existing tracked file, Git history, Git LFS, screenshots, or a `git add -f`. Inspect the exact staged/exported file list before publication. Do not upload the entire working directory as an archive.

## Credentials and signing

The app reads its key from macOS Keychain. Keychain service/account names, the public ASR endpoint, and resource IDs are identifiers, not account credentials. Test strings such as `secret-value`, `old-key` and `new-key` are fake fixtures.

Never include `~/.config/voxtype`, system/user keychain files, signing certificates/private keys, API keys, private recordings, preference exports or screenshots showing account data. If a real credential was previously published, revoke/rotate it; removing the current file does not invalidate copies or history.

The current working directory had no `.git` history at audit time, so no historical commits were audited. Before reusing an existing remote repository, review its history separately.

## Public claims

Keep ASR-only timings distinct from UI end-to-end latency. The published recognition set uses synthetic speech and no competitor client. Publish only the measured numbers with their scope; keep raw result hashes and scorer behavior aligned. Re-measure after code or service changes instead of retaining stale badges.

Source availability is separate from public binary distribution. The local certificate is not Developer ID/notarization. Inspect release archives separately, and include license/notice documents.

## 中文说明

不要直接把整个本地目录压缩上传。发布时核对实际文件清单，排除缓存、构建产物、开发记录、账号截图、密钥和签名材料。`.gitignore` 不会清除已被跟踪的文件或历史提交。

提交或推送前核对目标仓库和公开范围；如果目标远端已有历史，需要另查历史内容。源码公开不等于安装包已完成签名、公证或分发验证。
