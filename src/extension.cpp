// Copyright (C) 2026 Mitchell Scott
// SPDX-License-Identifier: GPL-3.0-only

#include <QByteArray>
#include <QHash>
#include <QMap>
#include <QMutex>
#include <QString>
#include <QtGui/private/qfontengine_p.h>
#include <QtGui/private/qfontsubset_p.h>
#include <QtGui/private/qpdf_p.h>
#include <QtGui/private/qtextengine_p.h>

#include "xovi.h"

namespace {

template <typename Function, typename Symbol>
Function symbolAs(Symbol symbol)
{
    return reinterpret_cast<Function>(reinterpret_cast<void *>(symbol));
}

QMutex glyphTextMutex;
QHash<QFontEngine::FaceId, QHash<glyph_t, QString>> glyphTextByFontFace;

constexpr int toUnicodeObjectOffsetInEmbedFont = 3;
constexpr qsizetype bfcharEntriesPerBlock = 100;

void recordTextPerGlyph(const QTextItemInt &textItem)
{
    if (!textItem.chars || !textItem.logClusters || textItem.num_chars <= 0 || !textItem.fontEngine)
        return;
    const int numGlyphs = textItem.glyphs.numGlyphs;
    const int firstCluster = textItem.logClusters[0];
    QList<QString> textForGlyphIndex(numGlyphs);
    for (int i = 0; i < textItem.num_chars; ++i) {
        const int glyphIndex = int(textItem.logClusters[i]) - firstCluster;
        if (glyphIndex < 0 || glyphIndex >= numGlyphs)
            return;
        textForGlyphIndex[glyphIndex].append(textItem.chars[i]);
    }

    QMutexLocker lock(&glyphTextMutex);
    QHash<glyph_t, QString> &glyphText = glyphTextByFontFace[textItem.fontEngine->faceId()];
    for (int i = 0; i < numGlyphs; ++i)
        if (!textForGlyphIndex.at(i).isEmpty() && !glyphText.contains(textItem.glyphs.glyphs[i]))
            glyphText.insert(textItem.glyphs.glyphs[i], textForGlyphIndex.at(i));
}

QList<int> reverseCmap(const QFontSubset *font)
{
    QList<int> reverseMap(font->nGlyphs(), 0);
    for (uint codepoint = 0; codepoint < 0x10000; ++codepoint) {
        const qsizetype subsetIndex = font->glyph_indices.indexOf(font->fontEngine->glyphIndex(codepoint));
        if (subsetIndex >= 0 && !reverseMap.at(subsetIndex))
            reverseMap[subsetIndex] = codepoint;
    }
    return reverseMap;
}

QByteArray toHex(ushort value)
{
    return QByteArray::number(value, 16).rightJustified(4, '0').toUpper();
}

QByteArray correctedToUnicodeMap(const QFontSubset *font, bool *recordedTextDiffersFromCmap)
{
    const QList<int> reverseMap = reverseCmap(font);
    QHash<glyph_t, QString> recordedText;
    {
        QMutexLocker lock(&glyphTextMutex);
        recordedText = glyphTextByFontFace.value(font->fontEngine->faceId());
    }

    *recordedTextDiffersFromCmap = false;
    QMap<qsizetype, QString> textForSubsetIndex;
    for (qsizetype subsetIndex = 1; subsetIndex < font->nGlyphs(); ++subsetIndex) {
        const QString recorded = recordedText.value(font->glyph_indices.at(subsetIndex));
        const int reverseMapped = reverseMap.at(subsetIndex);
        if (!recorded.isEmpty()) {
            textForSubsetIndex.insert(subsetIndex, recorded);
            if (!reverseMapped || recorded != QString(QChar(char16_t(reverseMapped))))
                *recordedTextDiffersFromCmap = true;
        } else if (reverseMapped) {
            textForSubsetIndex.insert(subsetIndex, QString(QChar(char16_t(reverseMapped))));
        }
    }

    QByteArray cmap = "/CIDInit /ProcSet findresource begin\n"
                      "12 dict begin\n"
                      "begincmap\n"
                      "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
                      "/CMapName /Adobe-Identity-UCS def\n"
                      "/CMapType 2 def\n"
                      "1 begincodespacerange\n"
                      "<0000> <FFFF>\n"
                      "endcodespacerange\n";
    const QList<qsizetype> subsetIndices = textForSubsetIndex.keys();
    for (qsizetype start = 0; start < subsetIndices.size(); start += bfcharEntriesPerBlock) {
        const qsizetype count = qMin(bfcharEntriesPerBlock, subsetIndices.size() - start);
        cmap += QByteArray::number(count) + " beginbfchar\n";
        for (qsizetype i = start; i < start + count; ++i) {
            const qsizetype subsetIndex = subsetIndices.at(i);
            cmap += '<' + toHex(ushort(subsetIndex)) + "> <";
            for (const QChar character : textForSubsetIndex.value(subsetIndex))
                cmap += toHex(character.unicode());
            cmap += ">\n";
        }
        cmap += "endbfchar\n";
    }
    cmap += "endcmap\n"
            "CMapName currentdict /CMap defineresource pop\n"
            "end\n"
            "end\n";
    return cmap;
}

void writeToUnicodeObject(QPdfEnginePrivate *engine, int toUnicodeObject, const QByteArray &cmap)
{
    using AddXrefEntry = int (*)(QPdfEnginePrivate *, int, bool);
    using Xprintf = void (*)(QPdfEnginePrivate *, const char *, ...);
    const auto addXrefEntry = symbolAs<AddXrefEntry>($_ZN17QPdfEnginePrivate12addXrefEntryEib);
    const auto xprintf = symbolAs<Xprintf>($_ZN17QPdfEnginePrivate7xprintfEPKcz);

    addXrefEntry(engine, toUnicodeObject, true);
    xprintf(engine, "<< /Length %lld >>\nstream\n", static_cast<long long>(cmap.size()));
    xprintf(engine, "%s", cmap.constData());
    xprintf(engine, "\nendstream\nendobj\n");
}

}

extern "C" bool override$_ZN10QPdfEngine5beginEP12QPaintDevice(QPdfEngine *self, QPaintDevice *device)
{
    using Begin = bool (*)(QPdfEngine *, QPaintDevice *);
    {
        QMutexLocker lock(&glyphTextMutex);
        glyphTextByFontFace.clear();
    }
    return symbolAs<Begin>($_ZN10QPdfEngine5beginEP12QPaintDevice)(self, device);
}

extern "C" void override$_ZN10QPdfEngine12drawTextItemERK7QPointFRK9QTextItem(
    QPdfEngine *self, const QPointF &position, const QTextItem &textItem)
{
    using DrawTextItem = void (*)(QPdfEngine *, const QPointF &, const QTextItem &);
    recordTextPerGlyph(static_cast<const QTextItemInt &>(textItem));
    symbolAs<DrawTextItem>($_ZN10QPdfEngine12drawTextItemERK7QPointFRK9QTextItem)(self, position, textItem);
}

extern "C" void override$_ZN17QPdfEnginePrivate9embedFontEP11QFontSubset(QPdfEnginePrivate *self, QFontSubset *font)
{
    using EmbedFont = void (*)(QPdfEnginePrivate *, QFontSubset *);
    const int toUnicodeObject = self->currentObject + toUnicodeObjectOffsetInEmbedFont;
    symbolAs<EmbedFont>($_ZN17QPdfEnginePrivate9embedFontEP11QFontSubset)(self, font);

    bool recordedTextDiffersFromCmap = false;
    const QByteArray cmap = correctedToUnicodeMap(font, &recordedTextDiffersFromCmap);
    if (recordedTextDiffersFromCmap)
        writeToUnicodeObject(self, toUnicodeObject, cmap);
}
