package org.pureswift.appruntime.ui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * Encodes trees the way AppRuntime's Swift `RenderCodec` does, so the tests
 * can build the bytes a guest sends.
 */
object TreeEncoder {

    fun encode(tree: IRNode): ByteArray {
        val strings = ArrayList<String>()
        collect(tree, strings)
        val out = ArrayList<Byte>()
        out += 0x52; out += 0x4E; out += 1
        strings(strings, out)
        node(tree, strings, out)
        return out.toByteArray()
    }

    private fun intern(string: String, strings: MutableList<String>) {
        if (string !in strings) strings += string
    }

    private fun collect(node: IRNode, strings: MutableList<String>) {
        intern(node.type, strings)
        collect(node.props, strings)
        for (modifier in node.modifiers) {
            intern(modifier.kind, strings)
            collect(modifier.args, strings)
        }
        node.children.forEach { collect(it, strings) }
    }

    private fun collect(props: Map<String, IRValue>, strings: MutableList<String>) {
        for (key in props.keys.sorted()) {
            intern(key, strings)
            collect(props.getValue(key), strings)
        }
    }

    private fun collect(value: IRValue, strings: MutableList<String>) {
        when (value) {
            is IRValue.Str -> intern(value.value, strings)
            is IRValue.Arr -> value.values.forEach { collect(it, strings) }
            else -> Unit
        }
    }

    private fun strings(strings: List<String>, out: MutableList<Byte>) {
        varint(strings.size.toLong(), out)
        for (string in strings) {
            val utf8 = string.encodeToByteArray()
            varint(utf8.size.toLong(), out)
            utf8.forEach { out += it }
        }
    }

    private fun node(node: IRNode, strings: List<String>, out: MutableList<Byte>) {
        varint(strings.indexOf(node.type).toLong(), out)
        fixed(node.id, out)
        props(node.props, strings, out)
        varint(node.modifiers.size.toLong(), out)
        for (modifier in node.modifiers) {
            varint(strings.indexOf(modifier.kind).toLong(), out)
            props(modifier.args, strings, out)
        }
        varint(node.children.size.toLong(), out)
        node.children.forEach { node(it, strings, out) }
        varint(node.count?.let { it + 1L } ?: 0, out)
    }

    private fun props(props: Map<String, IRValue>, strings: List<String>, out: MutableList<Byte>) {
        varint(props.size.toLong(), out)
        for (key in props.keys.sorted()) {
            varint(strings.indexOf(key).toLong(), out)
            value(props.getValue(key), strings, out)
        }
    }

    private fun value(value: IRValue, strings: List<String>, out: MutableList<Byte>) {
        when (value) {
            is IRValue.Str -> { out += 0; varint(strings.indexOf(value.value).toLong(), out) }
            is IRValue.Dbl -> { out += 1; fixed(value.value.toRawBits(), out) }
            is IRValue.Bool -> { out += 2; out += if (value.value) 1 else 0 }
            is IRValue.Int -> { out += 3; varint((value.value shl 1) xor (value.value shr 63), out) }
            is IRValue.Arr -> {
                out += 4
                varint(value.values.size.toLong(), out)
                value.values.forEach { value(it, strings, out) }
            }
        }
    }

    private fun varint(value: Long, out: MutableList<Byte>) {
        var v = value
        while (v.toULong() >= 0x80u) {
            out += ((v and 0x7F) or 0x80).toByte()
            v = v ushr 7
        }
        out += v.toByte()
    }

    private fun fixed(value: Long, out: MutableList<Byte>) {
        for (shift in 0 until 64 step 8) out += ((value ushr shift) and 0xFF).toByte()
    }
}

class RenderCodecTests {

    private val tree = IRNode(
        "VStack", id = -2, // 0xFFFF_FFFF_FFFF_FFFE: every bit of the u64 survives
        props = mapOf("alignment" to IRValue.Str("leading"), "spacing" to IRValue.Dbl(8.0)),
        modifiers = listOf(IRModifier("padding", mapOf("top" to IRValue.Dbl(16.0), "leading" to IRValue.Dbl(16.0)))),
        children = listOf(
            IRNode("Text", 2, mapOf("text" to IRValue.Str("Hello, wörld! 👋"))),
            IRNode("Stepper", 3, mapOf("value" to IRValue.Int(-300), "min" to IRValue.Int(Long.MIN_VALUE), "max" to IRValue.Int(Long.MAX_VALUE))),
            IRNode("Toggle", 4, mapOf("isOn" to IRValue.Bool(true), "columns" to IRValue.Arr(listOf(IRValue.Str("leading"), IRValue.Dbl(Double.POSITIVE_INFINITY))))),
            IRNode("List", 5, mapOf("revision" to IRValue.Int(7)), count = 3),
            IRNode("List", 6, count = 0),
        ),
    )

    @Test
    fun decodesWhatSwiftEncodes() {
        assertEquals(tree, RenderCodec.decode(TreeEncoder.encode(tree)))
    }

    @Test
    fun decodesTheIRDocumentsExample() {
        // RenderIR.md's format by hand: one Text node, ID 1, text "Hi".
        val bytes = byteArrayOf(
            0x52, 0x4E, 1,
            3, 4, 'T'.code.toByte(), 'e'.code.toByte(), 'x'.code.toByte(), 't'.code.toByte(),
            4, 't'.code.toByte(), 'e'.code.toByte(), 'x'.code.toByte(), 't'.code.toByte(),
            2, 'H'.code.toByte(), 'i'.code.toByte(),
            0, 1, 0, 0, 0, 0, 0, 0, 0,
            1, 1, 0, 2,
            0, 0, 0,
        )
        assertEquals(IRNode("Text", 1, mapOf("text" to IRValue.Str("Hi"))), RenderCodec.decode(bytes))
    }

    @Test
    fun roundTripsPayloads() {
        for (value in listOf(IRValue.Str("Ada"), IRValue.Int(-1), IRValue.Int(Long.MAX_VALUE), IRValue.Dbl(0.25), IRValue.Bool(false))) {
            assertEquals(value, RenderCodec.decodePayload(RenderCodec.encodePayload(value)))
        }
        // An int payload: no strings, tag 3, zigzag 4.
        assertEquals(listOf<Byte>(0, 3, 4), RenderCodec.encodePayload(IRValue.Int(2)).toList())
    }

    @Test
    fun rejectsBadInput() {
        val bytes = TreeEncoder.encode(tree)
        assertFailsWith<RenderDecodingException> { RenderCodec.decode(byteArrayOf(0x52, 0x4F, 1)) }
        assertFailsWith<RenderDecodingException> { RenderCodec.decode(byteArrayOf(0x52, 0x4E, 2)) }
        assertFailsWith<RenderDecodingException> { RenderCodec.decode(bytes.copyOf(bytes.size - 1)) }
        assertFailsWith<RenderDecodingException> { RenderCodec.decode(bytes + 0) }
        var deep = IRNode("Text", 0)
        repeat(600) { deep = IRNode("VStack", it.toLong(), children = listOf(deep)) }
        assertFailsWith<RenderDecodingException> { RenderCodec.decode(TreeEncoder.encode(deep)) }
    }

    @Test
    fun replacesSubtrees() {
        val replacement = IRNode("Text", 2, mapOf("text" to IRValue.Str("Bye")))
        val patched = tree.replacing(2, replacement)
        assertEquals(replacement, patched?.children?.first())
        assertEquals(tree.children.drop(1), patched?.children?.drop(1))
        assertEquals(null, tree.replacing(99, replacement))
    }
}
