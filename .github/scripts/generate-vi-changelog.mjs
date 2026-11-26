#!/usr/bin/env node
/**
 * Zero-dependency Auto SemVer & Vietnamese Changelog Generator for AntiRemote Releases.
 *
 * Usage:
 *   node .github/scripts/generate-vi-changelog.mjs [options]
 *
 * Options:
 *   --tag <vX.Y.Z>         Explicit release tag (skips auto semver bump)
 *   --bump <auto|patch|minor|major>  Semver bump strategy (default: auto)
 *   --signing <signed|unsigned>      IPA signing mode label
 *   --ipa-name <filename>            Built IPA filename for install instructions
 *   --sha256 <hex>                   SHA-256 checksum of the built IPA
 *   --out <path>                     Write Markdown changelog to file
 *   --github-output <path>           Append key=value outputs for GitHub Actions
 *   --dry-run                        Print metadata and changelog to stdout
 */

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const SCOPE_VI = {
  ios: 'iOS',
  app: 'Ứng dụng iOS',
  ui: 'Giao diện',
  chat: 'Trò chuyện & Streaming',
  control: 'Điều khiển từ xa',
  workspace: 'Không gian làm việc',
  settings: 'Cài đặt & Ghép nối',
  core: 'Lõi AntiCore',
  bridge: 'Bridge Daemon',
  api: 'API & WebSocket',
  security: 'Bảo mật',
  ci: 'CI/CD',
  release: 'Phát hành',
  docs: 'Tài liệu',
  deps: 'Phụ thuộc',
};

const VERB_PREFIX_VI = [
  [/^initial(?:ize| commit)?\b/i, 'Khởi tạo'],
  [/^add(?:ed|ing|s)?\b/i, 'Thêm'],
  [/^implement(?:ed|ing|s)?\b/i, 'Triển khai'],
  [/^create(?:d|s)?\b/i, 'Tạo'],
  [/^build(?:ing|s)?\b/i, 'Xây dựng'],
  [/^fix(?:ed|es|ing)?\b/i, 'Sửa'],
  [/^resolve(?:d|s)?\b/i, 'Khắc phục'],
  [/^update(?:d|s)?\b/i, 'Cập nhật'],
  [/^upgrade(?:d|s)?\b/i, 'Nâng cấp'],
  [/^bump(?:ed|s)?\b/i, 'Nâng phiên bản'],
  [/^improve(?:d|s)?\b/i, 'Cải thiện'],
  [/^enhance(?:d|s)?\b/i, 'Tăng cường'],
  [/^optimize(?:d|s)?\b/i, 'Tối ưu'],
  [/^refactor(?:ed|ing|s)?\b/i, 'Tái cấu trúc'],
  [/^remove(?:d|s)?\b/i, 'Xoá'],
  [/^delete(?:d|s)?\b/i, 'Xoá'],
  [/^drop(?:ped|s)?\b/i, 'Loại bỏ'],
  [/^support(?:ed|ing|s)?\b/i, 'Hỗ trợ'],
  [/^enable(?:d|s)?\b/i, 'Bật'],
  [/^disable(?:d|s)?\b/i, 'Tắt'],
  [/^configure(?:d|s)?\b/i, 'Cấu hình'],
  [/^harden(?:ed|s)?\b/i, 'Tăng cường bảo mật'],
  [/^prevent(?:ed|s)?\b/i, 'Ngăn chặn'],
  [/^handle(?:d|s)?\b/i, 'Xử lý'],
  [/^allow(?:ed|s)?\b/i, 'Cho phép'],
  [/^simplify(?:ied|ies)?\b/i, 'Đơn giản hoá'],
  [/^move(?:d|s)?\b/i, 'Di chuyển'],
  [/^rename(?:d|s)?\b/i, 'Đổi tên'],
  [/^revert(?:ed|s)?\b/i, 'Hoàn tác'],
];

const VIETNAMESE_DIACRITIC_RE = /[ăâđêôơưáàảãạắằẳẵặấầẩẫậéèẻẽẹếềểễệíìỉĩịóòỏõọốồổỗộớờởỡợúùủũụứừửữựýỳỷỹỵ]/i;

function git(args) {
  try {
    return execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  } catch {
    return '';
  }
}

export function parseSemver(tag) {
  const m = String(tag || '').trim().match(/^v?(\d+)\.(\d+)\.(\d+)$/);
  if (!m) return null;
  return { major: Number(m[1]), minor: Number(m[2]), patch: Number(m[3]) };
}

export function formatTag({ major, minor, patch }) {
  return `v${major}.${minor}.${patch}`;
}

export function parseCommit(raw) {
  const { hash, shortHash, author, date, subject, body } = raw;
  const cc = subject.match(/^([a-zA-Z]+)(?:\(([^)]+)\))?(!)?:\s*(.+)$/);
  const viOverrideMatch = body.match(/^\s*(?:Vi|Changelog-vi)\s*:\s*(.+)$/im);

  let type = 'other';
  let scope = null;
  let breaking = /BREAKING CHANGE:/i.test(body);
  let description = subject.trim();

  if (cc) {
    type = cc[1].toLowerCase();
    scope = cc[2] ? cc[2].trim().toLowerCase() : null;
    if (cc[3] === '!') breaking = true;
    description = cc[4].trim();
  }

  return {
    hash,
    shortHash,
    author,
    date,
    type,
    scope,
    breaking,
    description,
    viOverride: viOverrideMatch ? viOverrideMatch[1].trim() : null,
  };
}

export function localizeDescriptionVi(commit) {
  if (commit.viOverride) return commit.viOverride;
  const text = commit.description;
  if (VIETNAMESE_DIACRITIC_RE.test(text)) {
    return text.charAt(0).toUpperCase() + text.slice(1);
  }
  for (const [pattern, viVerb] of VERB_PREFIX_VI) {
    if (pattern.test(text)) {
      return text.replace(pattern, viVerb);
    }
  }
  return text.charAt(0).toUpperCase() + text.slice(1);
}

export function formatScopeVi(scope) {
  if (!scope) return '';
  const label = SCOPE_VI[scope] || scope.toUpperCase();
  return `**[${label}]** `;
}

export function computeNextVersion(prevTag, commits, bumpMode = 'auto') {
  const prev = parseSemver(prevTag);
  if (!prev) {
    return { major: 1, minor: 0, patch: 0 };
  }
  if (bumpMode === 'major') return { major: prev.major + 1, minor: 0, patch: 0 };
  if (bumpMode === 'minor') return { major: prev.major, minor: prev.minor + 1, patch: 0 };
  if (bumpMode === 'patch') return { major: prev.major, minor: prev.minor, patch: prev.patch + 1 };

  const hasBreaking = commits.some((c) => c.breaking);
  const hasFeat = commits.some((c) => c.type === 'feat');
  if (hasBreaking) return { major: prev.major + 1, minor: 0, patch: 0 };
  if (hasFeat) return { major: prev.major, minor: prev.minor + 1, patch: 0 };
  return { major: prev.major, minor: prev.minor, patch: prev.patch + 1 };
}

function getPreviousTag(explicitTag) {
  const tagsRaw = git(['tag', '--list', 'v*', '--sort=-v:refname']);
  const tags = tagsRaw ? tagsRaw.split('\n').map((t) => t.trim()).filter(Boolean) : [];
  for (const t of tags) {
    if (explicitTag && t === explicitTag) continue;
    if (parseSemver(t)) return t;
  }
  return '';
}

function collectCommits(prevTag) {
  const range = prevTag ? `${prevTag}..HEAD` : 'HEAD';
  const raw = git(['log', range, '--no-merges', '--format=%H%x1f%h%x1f%an%x1f%aI%x1f%s%x1f%b%x1e']);
  if (!raw) return [];
  return raw
    .split('\x1e')
    .map((entry) => entry.trim())
    .filter(Boolean)
    .map((entry) => {
      const [hash = '', shortHash = '', author = '', date = '', subject = '', body = ''] = entry.split('\x1f');
      return parseCommit({ hash, shortHash, author, date, subject, body });
    });
}

function formatVietnamDate(date = new Date()) {
  const fmt = new Intl.DateTimeFormat('vi-VN', {
    timeZone: 'Asia/Ho_Chi_Minh',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  });
  return `${fmt.format(date)} (GMT+7)`;
}

export function renderVietnameseChangelog({
  tag,
  prevTag,
  commits,
  signing = 'unsigned',
  ipaName = '',
  sha256 = '',
  repoSlug = '',
  headShort = '',
}) {
  const groups = {
    breaking: [],
    feat: [],
    fix: [],
    perf: [],
    refactor: [],
    ops: [],
    other: [],
  };

  for (const c of commits) {
    if (c.breaking) groups.breaking.push(c);
    if (c.type === 'feat') groups.feat.push(c);
    else if (c.type === 'fix') groups.fix.push(c);
    else if (c.type === 'perf') groups.perf.push(c);
    else if (c.type === 'refactor' || c.type === 'style') groups.refactor.push(c);
    else if (['docs', 'ci', 'build', 'test', 'chore'].includes(c.type)) groups.ops.push(c);
    else groups.other.push(c);
  }

  const formatBullet = (c) => {
    const scope = formatScopeVi(c.scope);
    const desc = localizeDescriptionVi(c);
    const commitRef = repoSlug && c.hash
      ? `([\`${c.shortHash}\`](https://github.com/${repoSlug}/commit/${c.hash}))`
      : `(\`${c.shortHash}\`)`;
    return `- ${scope}${desc} ${commitRef}`;
  };

  const lines = [];
  lines.push(`# Bản phát hành AntiRemote ${tag}`);
  lines.push('');
  lines.push(`> Ngày phát hành: **${formatVietnamDate()}** · Tổng số thay đổi: **${commits.length} commit**${headShort ? ` · Mã commit: \`${headShort}\`` : ''}`);
  lines.push('');

  if (!prevTag) {
    lines.push('Bản phát hành đầu tiên của **AntiRemote** — ứng dụng iOS SwiftUI thuần chuẩn Apple HIG điều khiển backend Google Antigravity (`agy`) từ xa qua companion bridge daemon.');
    lines.push('');
  }

  const sectionDefs = [
    ['## Thay đổi đột phá (Breaking Changes)', groups.breaking],
    ['## Tính năng mới', groups.feat],
    ['## Sửa lỗi', groups.fix],
    ['## Hiệu năng & Tối ưu', groups.perf],
    ['## Tái cấu trúc & Cải tiến mã nguồn', groups.refactor],
    ['## Tài liệu, Kiểm thử & CI/CD', groups.ops],
    ['## Thay đổi khác', groups.other],
  ];

  let hasAnySection = false;
  for (const [heading, items] of sectionDefs) {
    if (items.length === 0) continue;
    hasAnySection = true;
    lines.push(heading);
    lines.push('');
    for (const item of items) {
      lines.push(formatBullet(item));
    }
    lines.push('');
  }

  if (!hasAnySection) {
    lines.push('## Cập nhật bảo trì');
    lines.push('');
    lines.push('- Đóng gói lại bản dựng IPA mới nhất từ nhánh chính.');
    lines.push('');
  }

  lines.push('## Thông tin bản dựng IPA & Hướng dẫn cài đặt');
  lines.push('');
  if (signing === 'signed') {
    lines.push('- **Loại bản dựng:** IPA đã ký số bằng chứng chỉ Apple Developer (`Signed IPA`).');
    lines.push('- **Cách cài đặt:** Cài trực tiếp lên iPhone qua Apple Configurator, Xcode Devices hoặc công cụ phân phối nội bộ tương ứng hồ sơ Provisioning Profile.');
  } else {
    lines.push('- **Loại bản dựng:** IPA chưa ký số (`Unsigned IPA`) sẵn sàng để ký lại hoặc sideload.');
    lines.push('- **Cách cài đặt trên iPhone:** Tải tệp `.ipa` bên dưới và cài qua **AltStore**, **SideStore**, **Sideloadly**, **TrollStore** hoặc ký lại bằng Apple ID trên **Xcode**.');
    lines.push('- **Bật ký tự động trên GitHub Actions:** Thêm 4 biến mật trong *Repository Settings -> Secrets -> Actions*: `APPLE_CERT_BASE64`, `APPLE_CERT_PASSWORD`, `APPLE_PROVISIONING_PROFILE_BASE64`, `APPLE_TEAM_ID`.');
  }
  if (ipaName) {
    lines.push(`- **Tệp IPA:** \`${ipaName}\``);
  }
  if (sha256) {
    lines.push(`- **Mã kiểm tra SHA-256:** \`${sha256}\``);
  }
  lines.push('- **Kết nối máy chủ Antigravity từ xa:** Chạy `node bridge/src/cli.mjs --workspace <đường-dẫn-dự-án>` trên máy đích, sau đó mở **AntiRemote -> Cài đặt -> Pair Remote Machine via QR** để quét mã QR trên terminal.');
  lines.push('');

  if (prevTag && repoSlug) {
    lines.push(`**So sánh toàn bộ thay đổi:** https://github.com/${repoSlug}/compare/${prevTag}...${tag}`);
    lines.push('');
  }

  return `${lines.join('\n').trim()}\n`;
}

function parseCliArgs(argv) {
  const opts = {
    tag: '',
    bump: 'auto',
    signing: 'unsigned',
    ipaName: '',
    sha256: '',
    out: '',
    githubOutput: '',
    dryRun: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const next = argv[i + 1];
    if (a === '--tag' && next) { opts.tag = next; i += 1; }
    else if (a === '--bump' && next) { opts.bump = next; i += 1; }
    else if (a === '--signing' && next) { opts.signing = next; i += 1; }
    else if (a === '--ipa-name' && next) { opts.ipaName = next; i += 1; }
    else if (a === '--sha256' && next) { opts.sha256 = next; i += 1; }
    else if (a === '--out' && next) { opts.out = next; i += 1; }
    else if (a === '--github-output' && next) { opts.githubOutput = next; i += 1; }
    else if (a === '--dry-run') { opts.dryRun = true; }
  }
  return opts;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const opts = parseCliArgs(process.argv.slice(2));
  const explicitTag = opts.tag.trim();
  const prevTag = getPreviousTag(explicitTag);
  const commits = collectCommits(prevTag);
  const headShort = git(['rev-parse', '--short', 'HEAD']);

  let resolvedTag = explicitTag;
  if (!resolvedTag) {
    resolvedTag = formatTag(computeNextVersion(prevTag, commits, opts.bump));
  }
  const version = resolvedTag.replace(/^v/, '');
  const repoSlug = process.env.GITHUB_REPOSITORY || '';

  const markdown = renderVietnameseChangelog({
    tag: resolvedTag,
    prevTag,
    commits,
    signing: opts.signing,
    ipaName: opts.ipaName,
    sha256: opts.sha256,
    repoSlug,
    headShort,
  });

  if (opts.out) {
    fs.mkdirSync(path.dirname(opts.out), { recursive: true });
    fs.writeFileSync(opts.out, markdown, 'utf8');
  }

  if (opts.githubOutput) {
    const lines = [
      `tag=${resolvedTag}`,
      `version=${version}`,
      `prev_tag=${prevTag}`,
      `commit_count=${commits.length}`,
    ];
    fs.appendFileSync(opts.githubOutput, `${lines.join('\n')}\n`, 'utf8');
  }

  if (opts.dryRun || !opts.out) {
    process.stdout.write(markdown);
  }
}
