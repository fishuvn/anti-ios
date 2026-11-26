/**
 * Zero-dependency ISO/IEC 18004 QR Code encoder (Byte mode, ECC Level L, Versions 1..10).
 * Used to render scannable terminal pairing QR codes for AntiRemote iOS.
 */

// GF(256) with primitive polynomial 0x11D
const GF_EXP = new Uint8Array(512);
const GF_LOG = new Uint8Array(256);
{
  let x = 1;
  for (let i = 0; i < 255; i += 1) {
    GF_EXP[i] = x;
    GF_LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11d;
  }
  for (let i = 255; i < 512; i += 1) {
    GF_EXP[i] = GF_EXP[i - 255];
  }
}

function gfMul(a, b) {
  if (a === 0 || b === 0) return 0;
  return GF_EXP[GF_LOG[a] + GF_LOG[b]];
}

function rsGeneratorPoly(degree) {
  let poly = [1];
  for (let i = 0; i < degree; i += 1) {
    const next = new Array(poly.length + 1).fill(0);
    const factor = GF_EXP[i];
    for (let j = 0; j < poly.length; j += 1) {
      next[j] ^= poly[j];
      next[j + 1] ^= gfMul(poly[j], factor);
    }
    poly = next;
  }
  return poly;
}

function rsRemainder(data, ecLen) {
  const gen = rsGeneratorPoly(ecLen);
  const res = new Uint8Array(ecLen);
  for (const byte of data) {
    const factor = byte ^ res[0];
    res.copyWithin(0, 1);
    res[ecLen - 1] = 0;
    for (let i = 0; i < ecLen; i += 1) {
      res[i] ^= gfMul(gen[i + 1], factor);
    }
  }
  return res;
}

// Level L parameters for QR versions 1..10:
// [version, totalDataCodewords, ecPerBlock, blocksGroup1, dataPerBlock1, blocksGroup2, dataPerBlock2, alignCenters]
const VERSION_L_TABLE = [
  null,
  [1, 19, 7, 1, 19, 0, 0, []],
  [2, 34, 10, 1, 34, 0, 0, [6, 18]],
  [3, 55, 15, 1, 55, 0, 0, [6, 22]],
  [4, 80, 20, 1, 80, 0, 0, [6, 26]],
  [5, 108, 26, 1, 108, 0, 0, [6, 30]],
  [6, 136, 18, 2, 68, 0, 0, [6, 34]],
  [7, 156, 20, 2, 78, 0, 0, [6, 22, 38]],
  [8, 194, 24, 2, 97, 0, 0, [6, 24, 42]],
  [9, 232, 30, 2, 116, 0, 0, [6, 26, 46]],
  [10, 274, 18, 2, 68, 2, 69, [6, 28, 50]],
];

// Precomputed 15-bit format strings for ECC Level L (01) and masks 0..7 (with BCH + 0x5412 XOR mask)
const FORMAT_BITS_L = [
  0x77c4, 0x72f3, 0x7daa, 0x789d, 0x662f, 0x6318, 0x6c41, 0x6976,
];

// Precomputed 18-bit version info strings for versions 7..10
const VERSION_INFO_BITS = {
  7: 0x07c94,
  8: 0x085bc,
  9: 0x09a99,
  10: 0x0a4d3,
};

function selectVersion(byteLength) {
  for (let v = 1; v <= 10; v += 1) {
    const [, totalData] = VERSION_L_TABLE[v];
    const countBits = v <= 9 ? 8 : 16;
    const totalBitsNeeded = 4 + countBits + byteLength * 8;
    if (totalBitsNeeded <= totalData * 8) {
      return v;
    }
  }
  throw new Error(`QR payload too long (${byteLength} bytes; max 271 bytes)`);
}

function buildCodewords(bytes, version) {
  const [, totalData, ecPerBlock, b1, d1, b2, d2] = VERSION_L_TABLE[version];
  const bits = [];
  const pushBits = (val, width) => {
    for (let i = width - 1; i >= 0; i -= 1) {
      bits.push((val >>> i) & 1);
    }
  };

  // Byte mode indicator (0100)
  pushBits(0b0100, 4);
  pushBits(bytes.length, version <= 9 ? 8 : 16);
  for (const b of bytes) {
    pushBits(b, 8);
  }

  const maxBits = totalData * 8;
  // Terminator (up to 4 zero bits)
  const term = Math.min(4, maxBits - bits.length);
  pushBits(0, term);
  // Pad to byte boundary
  while (bits.length % 8 !== 0) bits.push(0);

  const data = [];
  for (let i = 0; i < bits.length; i += 8) {
    let byte = 0;
    for (let j = 0; j < 8; j += 1) {
      byte = (byte << 1) | bits[i + j];
    }
    data.push(byte);
  }

  let padToggle = 0;
  while (data.length < totalData) {
    data.push(padToggle % 2 === 0 ? 0xec : 0x11);
    padToggle += 1;
  }

  // Split into blocks and compute RS ECC
  const dataBlocks = [];
  const ecBlocks = [];
  let cursor = 0;
  for (let i = 0; i < b1; i += 1) {
    const slice = data.slice(cursor, cursor + d1);
    cursor += d1;
    dataBlocks.push(slice);
    ecBlocks.push(rsRemainder(slice, ecPerBlock));
  }
  for (let i = 0; i < b2; i += 1) {
    const slice = data.slice(cursor, cursor + d2);
    cursor += d2;
    dataBlocks.push(slice);
    ecBlocks.push(rsRemainder(slice, ecPerBlock));
  }

  // Interleave data codewords, then EC codewords
  const out = [];
  const maxDataLen = Math.max(d1, d2);
  for (let i = 0; i < maxDataLen; i += 1) {
    for (const blk of dataBlocks) {
      if (i < blk.length) out.push(blk[i]);
    }
  }
  for (let i = 0; i < ecPerBlock; i += 1) {
    for (const blk of ecBlocks) {
      out.push(blk[i]);
    }
  }
  return out;
}

function drawFinder(modules, isFunc, top, left) {
  const size = modules.length;
  for (let dy = -1; dy <= 7; dy += 1) {
    for (let dx = -1; dx <= 7; dx += 1) {
      const r = top + dy;
      const c = left + dx;
      if (r < 0 || r >= size || c < 0 || c >= size) continue;
      const dist = Math.max(Math.abs(dy - 3), Math.abs(dx - 3));
      const dark = dist !== 2 && dist !== 4;
      modules[r][c] = dark;
      isFunc[r][c] = true;
    }
  }
}

function drawAlignment(modules, isFunc, cy, cx) {
  for (let dy = -2; dy <= 2; dy += 1) {
    for (let dx = -2; dx <= 2; dx += 1) {
      const dist = Math.max(Math.abs(dy), Math.abs(dx));
      modules[cy + dy][cx + dx] = dist !== 1;
      isFunc[cy + dy][cx + dx] = true;
    }
  }
}

function applyFormat(modules, isFunc, mask) {
  const size = modules.length;
  const bits = FORMAT_BITS_L[mask];
  const setBit = (r, c, idx) => {
    modules[r][c] = ((bits >>> idx) & 1) !== 0;
    isFunc[r][c] = true;
  };

  // Top-left copy (MSB = bit 14)
  for (let i = 0; i <= 5; i += 1) setBit(8, i, 14 - i);
  setBit(8, 7, 8);
  setBit(8, 8, 7);
  setBit(7, 8, 6);
  for (let i = 9; i < 15; i += 1) setBit(14 - i, 8, 14 - i);

  // Second copy (bottom-left vertical + top-right horizontal)
  for (let i = 0; i < 7; i += 1) setBit(size - 1 - i, 8, 14 - i);
  for (let i = 7; i < 15; i += 1) setBit(8, size - 15 + i, 14 - i);

  // Dark module
  modules[size - 8][8] = true;
  isFunc[size - 8][8] = true;
}

function applyVersionInfo(modules, isFunc, version) {
  const bits = VERSION_INFO_BITS[version];
  if (bits === undefined) return;
  const size = modules.length;
  for (let i = 0; i < 18; i += 1) {
    const dark = ((bits >>> i) & 1) !== 0;
    const a = size - 11 + (i % 3);
    const b = Math.floor(i / 3);
    modules[b][a] = dark;
    isFunc[b][a] = true;
    modules[a][b] = dark;
    isFunc[a][b] = true;
  }
}

function maskCondition(mask, r, c) {
  switch (mask) {
    case 0: return (r + c) % 2 === 0;
    case 1: return r % 2 === 0;
    case 2: return c % 3 === 0;
    case 3: return (r + c) % 3 === 0;
    case 4: return (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0;
    case 5: return ((r * c) % 2) + ((r * c) % 3) === 0;
    case 6: return (((r * c) % 2) + ((r * c) % 3)) % 2 === 0;
    case 7: return (((r + c) % 2) + ((r * c) % 3)) % 2 === 0;
    default: return false;
  }
}

function penaltyScore(modules) {
  const n = modules.length;
  let score = 0;
  // Rule 1: adjacent runs >= 5
  for (let r = 0; r < n; r += 1) {
    let runColor = modules[r][0];
    let runLen = 1;
    for (let c = 1; c < n; c += 1) {
      if (modules[r][c] === runColor) {
        runLen += 1;
        if (runLen === 5) score += 3;
        else if (runLen > 5) score += 1;
      } else {
        runColor = modules[r][c];
        runLen = 1;
      }
    }
  }
  for (let c = 0; c < n; c += 1) {
    let runColor = modules[0][c];
    let runLen = 1;
    for (let r = 1; r < n; r += 1) {
      if (modules[r][c] === runColor) {
        runLen += 1;
        if (runLen === 5) score += 3;
        else if (runLen > 5) score += 1;
      } else {
        runColor = modules[r][c];
        runLen = 1;
      }
    }
  }
  // Rule 2: 2x2 blocks
  for (let r = 0; r < n - 1; r += 1) {
    for (let c = 0; c < n - 1; c += 1) {
      const v = modules[r][c];
      if (v === modules[r][c + 1] && v === modules[r + 1][c] && v === modules[r + 1][c + 1]) {
        score += 3;
      }
    }
  }
  return score;
}

/**
 * Encodes text into a boolean QR matrix (true = dark module).
 */
export function encodeQRMatrix(text) {
  const bytes = Buffer.from(String(text), 'utf8');
  const version = selectVersion(bytes.length);
  const size = version * 4 + 17;
  const codewords = buildCodewords(bytes, version);

  const baseModules = Array.from({ length: size }, () => Array(size).fill(false));
  const isFunc = Array.from({ length: size }, () => Array(size).fill(false));

  // Timing patterns
  for (let i = 0; i < size; i += 1) {
    baseModules[6][i] = i % 2 === 0;
    isFunc[6][i] = true;
    baseModules[i][6] = i % 2 === 0;
    isFunc[i][6] = true;
  }

  // Finders
  drawFinder(baseModules, isFunc, 0, 0);
  drawFinder(baseModules, isFunc, 0, size - 7);
  drawFinder(baseModules, isFunc, size - 7, 0);

  // Alignments
  const centers = VERSION_L_TABLE[version][7];
  for (const cy of centers) {
    for (const cx of centers) {
      if ((cy === 6 && cx === 6) || (cy === 6 && cx === size - 7) || (cy === size - 7 && cx === 6)) {
        continue;
      }
      drawAlignment(baseModules, isFunc, cy, cx);
    }
  }

  // Reserve format & version areas
  applyFormat(baseModules, isFunc, 0);
  applyVersionInfo(baseModules, isFunc, version);

  // Place data bits in zigzag columns
  let bitIdx = 0;
  const totalBits = codewords.length * 8;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    const upward = ((right + 1) & 2) === 0;
    for (let vert = 0; vert < size; vert += 1) {
      const r = upward ? size - 1 - vert : vert;
      for (let j = 0; j < 2; j += 1) {
        const c = right - j;
        if (isFunc[r][c]) continue;
        let dark = false;
        if (bitIdx < totalBits) {
          dark = ((codewords[bitIdx >>> 3] >>> (7 - (bitIdx & 7))) & 1) !== 0;
          bitIdx += 1;
        }
        baseModules[r][c] = dark;
      }
    }
  }

  // Choose lowest-penalty mask
  let bestMask = 0;
  let bestScore = Infinity;
  let bestMatrix = null;

  for (let mask = 0; mask < 8; mask += 1) {
    const candidate = baseModules.map((row) => row.slice());
    for (let r = 0; r < size; r += 1) {
      for (let c = 0; c < size; c += 1) {
        if (!isFunc[r][c] && maskCondition(mask, r, c)) {
          candidate[r][c] = !candidate[r][c];
        }
      }
    }
    applyFormat(candidate, isFunc, mask);
    const score = penaltyScore(candidate);
    if (score < bestScore) {
      bestScore = score;
      bestMask = mask;
      bestMatrix = candidate;
    }
  }

  return { version, size, mask: bestMask, matrix: bestMatrix };
}

/**
 * Renders a QR matrix into compact terminal half-blocks (black on white quiet zone).
 */
export function renderTerminalQR(text, quietZone = 2) {
  const { size, matrix } = encodeQRMatrix(text);
  const full = size + quietZone * 2;
  const isDark = (r, c) => {
    const mr = r - quietZone;
    const mc = c - quietZone;
    if (mr < 0 || mr >= size || mc < 0 || mc >= size) return false;
    return matrix[mr][mc];
  };

  const lines = [];
  for (let r = 0; r < full; r += 2) {
    let line = '';
    for (let c = 0; c < full; c += 1) {
      const top = isDark(r, c);
      const bot = r + 1 < full ? isDark(r + 1, c) : false;
      // On dark terminal themes, light modules use bright block so iOS Camera detects contrast cleanly
      if (top && bot) line += ' ';
      else if (top && !bot) line += '▄';
      else if (!top && bot) line += '▀';
      else line += '█';
    }
    lines.push(line);
  }
  return lines.join('\n');
}
