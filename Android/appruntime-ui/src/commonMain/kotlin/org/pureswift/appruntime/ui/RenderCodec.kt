package org.pureswift.appruntime.ui

// AppRuntime's render IR (Documentation/RenderIR.md there), decoded the way
// its Swift `RenderCodec` does: version 1, little-endian.
//
//   tree      := 0x52 0x4E ("RN"), version u8 = 1, strings, node
//   strings   := varint count, (varint length, UTF-8 bytes)*
//   node      := varint type, u64 id, props, modifiers, children, varint lazy
//   props     := varint count, (varint key, value)*          keys sorted
//   value     := u8 tag, then
//                  0 string: varint string index
//                  1 double: f64
//                  2 bool:   u8 0 or 1
//                  3 int:    zigzag varint
//                  4 array:  varint count, value*
//   modifiers := varint count, (varint kind, props)*
//   children  := varint count, node*
//   lazy      := 0 for an eager node, rows + 1 for a lazy container
//   payload   := strings, value                               (event payloads)

/** A prop or modifier argument. */
sealed interface IRValue {
    data class Str(val value: String) : IRValue
    data class Dbl(val value: Double) : IRValue
    data class Bool(val value: Boolean) : IRValue
    data class Int(val value: Long) : IRValue
    data class Arr(val values: List<IRValue>) : IRValue
}

val IRValue?.string: String? get() = (this as? IRValue.Str)?.value

/** A number, from a double or an int, as Swift's `PropValue.double` reads it. */
val IRValue?.double: Double?
    get() = when (this) {
        is IRValue.Dbl -> value
        is IRValue.Int -> value.toDouble()
        else -> null
    }

val IRValue?.bool: Boolean? get() = (this as? IRValue.Bool)?.value

val IRValue?.long: Long? get() = (this as? IRValue.Int)?.value

val IRValue?.array: List<IRValue>? get() = (this as? IRValue.Arr)?.values

/** One entry of a node's modifier chain, in order. */
data class IRModifier(val kind: String, val args: Map<String, IRValue> = emptyMap())

/** A node of the guest's tree. `id` is the u64 node ID, as its bits. */
data class IRNode(
    val type: String,
    val id: Long,
    val props: Map<String, IRValue> = emptyMap(),
    val modifiers: List<IRModifier> = emptyList(),
    val children: List<IRNode> = emptyList(),
    /** Rows in a lazy container; `null` for an eager node. */
    val count: Int? = null,
) {
    operator fun get(key: String): IRValue? = props[key]

    /** One line per node, indented: its type, ID, props and modifiers, for debugging. */
    fun outline(indent: String = ""): String = buildString {
        append(indent).append(type).append(" #").append(id.toULong())
        count?.let { append(" rows=").append(it) }
        if (props.isNotEmpty()) append(" ").append(props)
        if (modifiers.isNotEmpty()) append(" .").append(modifiers.joinToString(" .") { "${it.kind}${it.args}" })
        append('\n')
        children.forEach { append(it.outline("$indent  ")) }
    }

    /** This tree with node `id` replaced by `replacement`, or `null` when `id` isn't in it. */
    fun replacing(id: Long, replacement: IRNode): IRNode? {
        if (this.id == id) return replacement
        for ((index, child) in children.withIndex()) {
            val patched = child.replacing(id, replacement) ?: continue
            return copy(children = children.toMutableList().also { it[index] = patched })
        }
        return null
    }
}

/** Why bytes aren't a render tree. */
class RenderDecodingException(message: String) : Exception(message)

/** `RenderEventKind`. */
object RenderEventKind {
    const val TAP = 1
    const val CHANGE = 2
    const val SUBMIT = 3
    const val POP = 4
    const val REFRESH = 5
    const val FOCUS = 6
}

object RenderCodec {

    const val VERSION = 1

    fun decode(bytes: ByteArray): IRNode {
        val reader = Reader(bytes)
        if (reader.byte() != 0x52 || reader.byte() != 0x4E) throw RenderDecodingException("not a render tree")
        val version = reader.byte()
        if (version != VERSION) throw RenderDecodingException("unsupported version $version")
        reader.readStrings()
        val node = reader.node()
        reader.finish()
        return node
    }

    fun decodePayload(bytes: ByteArray): IRValue {
        val reader = Reader(bytes)
        reader.readStrings()
        val value = reader.value()
        reader.finish()
        return value
    }

    /** An event payload: a one-string table when the value is a string. */
    fun encodePayload(value: IRValue): ByteArray {
        val strings = mutableListOf<String>()
        collect(value, strings)
        val out = Writer()
        out.varint(strings.size.toLong())
        for (string in strings) {
            val utf8 = string.encodeToByteArray()
            out.varint(utf8.size.toLong())
            out.bytes(utf8)
        }
        out.value(value, strings)
        return out.toByteArray()
    }

    private fun collect(value: IRValue, strings: MutableList<String>) {
        when (value) {
            is IRValue.Str -> if (value.value !in strings) strings.add(value.value)
            is IRValue.Arr -> value.values.forEach { collect(it, strings) }
            else -> Unit
        }
    }

    private class Writer {
        private var buffer = ByteArray(32)
        private var size = 0

        fun byte(value: Int) {
            if (size == buffer.size) buffer = buffer.copyOf(buffer.size * 2)
            buffer[size++] = value.toByte()
        }

        fun bytes(value: ByteArray) = value.forEach { byte(it.toInt()) }

        fun varint(value: Long) {
            var v = value
            while (v.toULong() >= 0x80u) {
                byte(((v and 0x7F) or 0x80).toInt())
                v = v ushr 7
            }
            byte(v.toInt())
        }

        fun fixed(value: Long) {
            for (shift in 0 until 64 step 8) byte(((value ushr shift) and 0xFF).toInt())
        }

        fun value(value: IRValue, strings: List<String>) {
            when (value) {
                is IRValue.Str -> { byte(0); varint(strings.indexOf(value.value).toLong()) }
                is IRValue.Dbl -> { byte(1); fixed(value.value.toRawBits()) }
                is IRValue.Bool -> { byte(2); byte(if (value.value) 1 else 0) }
                is IRValue.Int -> { byte(3); varint((value.value shl 1) xor (value.value shr 63)) }
                is IRValue.Arr -> {
                    byte(4)
                    varint(value.values.size.toLong())
                    value.values.forEach { value(it, strings) }
                }
            }
        }

        fun toByteArray(): ByteArray = buffer.copyOf(size)
    }

    private class Reader(private val bytes: ByteArray) {
        private var position = 0
        private var strings: Array<String> = emptyArray()
        private var depth = 0

        fun byte(): Int {
            if (position >= bytes.size) throw RenderDecodingException("truncated")
            return bytes[position++].toInt() and 0xFF
        }

        fun varint(): Long {
            var result = 0L
            var shift = 0
            while (true) {
                val byte = byte()
                if (shift >= 64) throw RenderDecodingException("malformed varint")
                result = result or ((byte and 0x7F).toLong() shl shift)
                if (byte and 0x80 == 0) return result
                shift += 7
            }
        }

        /** A count: every element takes at least one byte. */
        fun count(): Int {
            val value = varint()
            if (value < 0 || value > (bytes.size - position).toLong()) throw RenderDecodingException("truncated")
            return value.toInt()
        }

        fun fixed(): Long {
            var value = 0L
            for (shift in 0 until 64 step 8) value = value or (byte().toLong() shl shift)
            return value
        }

        fun readStrings() {
            val count = count()
            strings = Array(count) {
                val length = count()
                val string = bytes.decodeToString(position, position + length)
                position += length
                string
            }
        }

        fun string(): String {
            val index = varint()
            if (index < 0 || index >= strings.size) throw RenderDecodingException("string index out of range")
            return strings[index.toInt()]
        }

        fun node(): IRNode {
            if (++depth > 512) throw RenderDecodingException("nested too deeply")
            val type = string()
            val id = fixed()
            val props = props()
            val modifiers = List(count()) { IRModifier(string(), props()) }
            val children = List(count()) { node() }
            val lazy = varint()
            depth--
            return IRNode(type, id, props, modifiers, children, if (lazy == 0L) null else (lazy - 1).toInt())
        }

        fun props(): Map<String, IRValue> {
            val count = count()
            if (count == 0) return emptyMap()
            val props = LinkedHashMap<String, IRValue>(count)
            repeat(count) {
                val key = string()
                props[key] = value()
            }
            return props
        }

        fun value(): IRValue {
            if (++depth > 512) throw RenderDecodingException("nested too deeply")
            val value = when (byte()) {
                0 -> IRValue.Str(string())
                1 -> IRValue.Dbl(Double.fromBits(fixed()))
                2 -> IRValue.Bool(byte() != 0)
                3 -> {
                    val zigzag = varint()
                    IRValue.Int((zigzag ushr 1) xor -(zigzag and 1))
                }
                4 -> IRValue.Arr(List(count()) { value() })
                else -> throw RenderDecodingException("unknown value tag")
            }
            depth--
            return value
        }

        fun finish() {
            if (position != bytes.size) throw RenderDecodingException("trailing bytes")
        }
    }
}
