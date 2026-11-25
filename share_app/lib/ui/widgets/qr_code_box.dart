import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Lightweight pure-Dart ISO-18004 QR Code encoder (Byte mode, ECC Level L,
/// Versions 1..6 covering up to 134 UTF-8 bytes) so Share's long-image footer
/// and QR cards render genuine scannable QR codes with zero extra dependencies.
class QrCodeMatrix {
  final int size;
  final List<bool> modules; // size * size, row-major, true = dark

  const QrCodeMatrix._(this.size, this.modules);

  bool at(int r, int c) => modules[r * size + c];

  // (totalCodewords, dataCodewords, ecCodewordsPerBlock, alignmentCenter)
  static const _versionSpecs = <(int, int, int, List<int>)>[
    (26, 19, 7, []), // V1: 21x21, max 17 bytes
    (44, 34, 10, [6, 18]), // V2: 25x25, max 32 bytes
    (70, 55, 15, [6, 22]), // V3: 29x29, max 53 bytes
    (100, 80, 20, [6, 26]), // V4: 33x33, max 78 bytes
    (134, 108, 26, [6, 30]), // V5: 37x37, max 106 bytes
    (172, 136, 18, [6, 34]), // V6: 41x41, 2 blocks of 68 data + 18 EC (max 134 bytes)
  ];

  // Precomputed Format Info bits for ECC=L(01) + Mask=0..7, BCH(15,5) + XOR 0x5412
  static const _formatBitsMask0 = 0x77C4; // ECC=01(L), mask=000

  // Version info 18-bit BCH doesn't apply until V7, so V1..V6 need none.

  static QrCodeMatrix encode(String content) {
    final dataBytes = Uint8List.fromList(utf8.encode(content));
    int version = 6;
    for (int v = 1; v <= 6; v++) {
      final (_, dataCap, _, _) = _versionSpecs[v - 1];
      // 4 bits mode + 8 bits length + payload + 4 bits terminator -> bytes needed
      if (2 + dataBytes.length <= dataCap) {
        version = v;
        break;
      }
    }

    final (totalCw, dataCw, ecPerBlock, alignCenters) = _versionSpecs[version - 1];
    final blocks = version == 6 ? 2 : 1;
    final dataPerBlock = dataCw ~/ blocks;

    // Encode byte-mode bitstream into dataCw bytes
    final bits = <int>[];
    void pushBits(int val, int count) {
      for (int i = count - 1; i >= 0; i--) {
        bits.add((val >> i) & 1);
      }
    }

    final payloadLen = dataBytes.length.clamp(0, dataCw - 2);
    pushBits(0x4, 4); // Byte mode
    pushBits(payloadLen, 8);
    for (int i = 0; i < payloadLen; i++) {
      pushBits(dataBytes[i], 8);
    }
    final remaining = dataCw * 8 - bits.length;
    if (remaining > 0) {
      pushBits(0, remaining.clamp(0, 4));
    }
    while (bits.length % 8 != 0) {
      bits.add(0);
    }
    final codewords = Uint8List(dataCw);
    int cwIdx = 0;
    for (int i = 0; i < bits.length && cwIdx < dataCw; i += 8) {
      int b = 0;
      for (int j = 0; j < 8; j++) {
        b = (b << 1) | bits[i + j];
      }
      codewords[cwIdx++] = b;
    }
    var padToggle = true;
    while (cwIdx < dataCw) {
      codewords[cwIdx++] = padToggle ? 0xEC : 0x11;
      padToggle = !padToggle;
    }

    // Build data blocks + Reed-Solomon ECC blocks & interleave
    final dataBlocks = <Uint8List>[];
    final ecBlocks = <Uint8List>[];
    for (int b = 0; b < blocks; b++) {
      final slice = Uint8List.sublistView(
        codewords,
        b * dataPerBlock,
        (b + 1) * dataPerBlock,
      );
      dataBlocks.add(slice);
      ecBlocks.add(_rsCompute(slice, ecPerBlock));
    }

    final finalStream = Uint8List(totalCw);
    int outIdx = 0;
    for (int i = 0; i < dataPerBlock; i++) {
      for (int b = 0; b < blocks; b++) {
        finalStream[outIdx++] = dataBlocks[b][i];
      }
    }
    for (int i = 0; i < ecPerBlock; i++) {
      for (int b = 0; b < blocks; b++) {
        finalStream[outIdx++] = ecBlocks[b][i];
      }
    }

    // Build QR matrix
    final size = 17 + 4 * version;
    final grid = List<bool>.filled(size * size, false);
    final isFunc = List<bool>.filled(size * size, false);

    void setFunc(int r, int c, bool dark) {
      if (r < 0 || r >= size || c < 0 || c >= size) return;
      grid[r * size + c] = dark;
      isFunc[r * size + c] = true;
    }

    void drawFinder(int top, int left) {
      for (int dr = -1; dr <= 7; dr++) {
        for (int dc = -1; dc <= 7; dc++) {
          final r = top + dr;
          final c = left + dc;
          if (r < 0 || r >= size || c < 0 || c >= size) continue;
          final inBorder = dr >= 0 && dr <= 6 && dc >= 0 && dc <= 6;
          final dark = inBorder &&
              (dr == 0 ||
                  dr == 6 ||
                  dc == 0 ||
                  dc == 6 ||
                  (dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4));
          setFunc(r, c, dark);
        }
      }
    }

    drawFinder(0, 0);
    drawFinder(0, size - 7);
    drawFinder(size - 7, 0);

    // Alignment pattern for V2..V6
    if (alignCenters.length >= 2) {
      final r = alignCenters.last;
      final c = alignCenters.last;
      for (int dr = -2; dr <= 2; dr++) {
        for (int dc = -2; dc <= 2; dc++) {
          final dark = dr.abs() == 2 || dc.abs() == 2 || (dr == 0 && dc == 0);
          setFunc(r + dr, c + dc, dark);
        }
      }
    }

    // Timing patterns
    for (int i = 8; i < size - 8; i++) {
      final dark = i.isEven;
      if (!isFunc[6 * size + i]) setFunc(6, i, dark);
      if (!isFunc[i * size + 6]) setFunc(i, 6, dark);
    }

    // Reserve format info & dark module
    setFunc(size - 8, 8, true);
    for (int i = 0; i < 15; i++) {
      final bit = ((_formatBitsMask0 >> i) & 1) == 1;
      // Horizontal/Vertical top-left
      if (i < 6) {
        setFunc(i, 8, bit);
      } else if (i < 8) {
        setFunc(i + 1, 8, bit);
      } else {
        setFunc(size - 15 + i, 8, bit);
      }
      if (i < 8) {
        setFunc(8, size - 1 - i, bit);
      } else if (i < 9) {
        setFunc(8, 7, bit);
      } else {
        setFunc(8, 14 - i, bit);
      }
    }

    // Place data + EC bits in standard zigzag with Mask 0 ((r + c) % 2 == 0)
    int bitPos = 0;
    final totalBits = finalStream.length * 8;
    var up = true;
    for (int right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      for (int step = 0; step < size; step++) {
        final r = up ? size - 1 - step : step;
        for (int colOff = 0; colOff < 2; colOff++) {
          final c = right - colOff;
          if (isFunc[r * size + c]) continue;
          var dataBit = false;
          if (bitPos < totalBits) {
            final byteVal = finalStream[bitPos >> 3];
            dataBit = ((byteVal >> (7 - (bitPos & 7))) & 1) == 1;
            bitPos++;
          }
          final masked = dataBit ^ ((r + c).isEven);
          grid[r * size + c] = masked;
        }
      }
      up = !up;
    }

    return QrCodeMatrix._(size, grid);
  }

  static Uint8List _rsCompute(Uint8List data, int degree) {
    final gen = _rsGenerator(degree);
    final res = Uint8List(degree);
    for (final b in data) {
      final factor = b ^ res[0];
      for (int i = 0; i < degree - 1; i++) {
        res[i] = res[i + 1] ^ _gfMul(gen[i], factor);
      }
      res[degree - 1] = _gfMul(gen[degree - 1], factor);
    }
    return res;
  }

  static List<int> _rsGenerator(int degree) {
    var poly = List<int>.filled(degree, 0);
    poly[degree - 1] = 1;
    int root = 1;
    for (int i = 0; i < degree; i++) {
      for (int j = 0; j < degree; j++) {
        poly[j] = _gfMul(poly[j], root);
        if (j + 1 < degree) poly[j] ^= poly[j + 1];
      }
      root = _gfMul(root, 0x02);
    }
    return poly;
  }

  static int _gfMul(int x, int y) {
    int z = 0;
    for (int i = 7; i >= 0; i--) {
      z = (z << 1) ^ ((z >> 7) * 0x11D);
      z ^= ((y >> i) & 1) * x;
    }
    return z;
  }
}

class QrCodeBox extends StatelessWidget {
  final String data;
  final double size;
  final Color darkColor;
  final Color lightColor;

  const QrCodeBox({
    super.key,
    required this.data,
    this.size = 68,
    this.darkColor = const Color(0xFF1A1A1D),
    this.lightColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    final matrix = QrCodeMatrix.encode(data);
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: lightColor,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0x18000000), width: 0.5),
      ),
      child: CustomPaint(
        painter: _QrPainter(matrix, darkColor),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  final QrCodeMatrix matrix;
  final Color darkColor;

  _QrPainter(this.matrix, this.darkColor);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = darkColor
      ..style = PaintingStyle.fill;
    final cell = size.width / matrix.size;
    for (int r = 0; r < matrix.size; r++) {
      for (int c = 0; c < matrix.size; c++) {
        if (matrix.at(r, c)) {
          canvas.drawRect(
            Rect.fromLTWH(c * cell, r * cell, cell + 0.15, cell + 0.15),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter oldDelegate) =>
      oldDelegate.matrix != matrix || oldDelegate.darkColor != darkColor;
}
