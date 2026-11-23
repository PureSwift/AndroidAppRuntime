package org.pureswift.appruntime.ui

import com.pureswift.swiftui.CallbackSink
import com.pureswift.swiftui.SwiftBridge
import com.pureswift.swiftui.TreeStore
import com.pureswift.swiftui.ViewNode

/**
 * The guest's side of the player: the host's `NativeHost` natives that reach
 * its `RendererDelegate` (Documentation/Plan.md §7.1). Main thread only.
 */
interface RenderEvents {

    /** The user acted on `node`; the guest's update arrives before this returns. */
    fun event(node: Long, kind: Int, payload: ByteArray)

    /** Row `index` of the lazy container `list`, as an encoded tree. */
    fun row(list: Long, index: Int): ByteArray
}

/**
 * The renderer's surface: the Swift host's `AndroidRenderer` sends it the
 * guest's trees, and composeui renders its `store`.
 *
 * It keeps the guest's tree, so `replaceSubtree` patches it and the adapter
 * rebuilds composeui's tree; callback IDs stay stable, so Compose recomposes
 * only what changed. It is composeui's `CallbackSink` too, turning callbacks
 * into guest events and fetching lazy rows.
 *
 * One per process: it outlives the Activity, so a recreated Activity shows
 * the same tree.
 */
class RenderSurface(private val events: RenderEvents) : CallbackSink {

    val store = TreeStore()

    val adapter = IRAdapter()

    var log: (String) -> Unit
        get() = adapter.log
        set(value) { adapter.log = value }

    /** Where each tree and row goes, as an outline, when debugging. */
    var trace: ((String) -> Unit)? = null

    /** The guest's tree now. */
    var tree: IRNode? = null
        private set

    /** Light or dark: named colors follow it. */
    var dark: Boolean
        get() = adapter.dark
        set(value) {
            if (value != adapter.dark) {
                adapter.dark = value
                publish()
            }
        }

    /** Makes this the sink composeui calls. */
    fun install() {
        SwiftBridge.sink = this
    }

    // MARK: From the host (Swift calls these by name)

    /** `Renderer.apply`: replaces everything. */
    fun apply(tree: ByteArray) {
        try {
            this.tree = RenderCodec.decode(tree)
        } catch (error: RenderDecodingException) {
            log("the app sent a tree this player can't read: ${error.message}")
            return
        }
        publish()
    }

    /** `Renderer.replaceSubtree`: replaces node `id` and its subtree. */
    fun replaceSubtree(id: Long, tree: ByteArray) {
        val subtree = try {
            RenderCodec.decode(tree)
        } catch (error: RenderDecodingException) {
            log("the app sent a subtree this player can't read: ${error.message}")
            return
        }
        val patched = this.tree?.replacing(id, subtree)
        if (patched == null) {
            log("the app replaced node ${IRAdapter.idString(id)}, which isn't on screen")
            return
        }
        this.tree = patched
        publish()
    }

    /**
     * The system back gesture: pops the deepest `NavStack` that has a level
     * to go back to, and returns whether there was one.
     */
    fun goBack(): Boolean {
        val stack = tree?.let(::poppable) ?: return false
        send(stack.id, RenderEventKind.POP, IRValue.Int((stack.children.size - 1).toLong()))
        return true
    }

    private fun poppable(node: IRNode): IRNode? {
        for (child in node.children.asReversed()) {
            poppable(child)?.let { return it }
        }
        return if (node.type == "NavStack" && node.children.size > 1) node else null
    }

    private fun publish() {
        trace?.let { trace -> tree?.let { trace("tree:\n" + it.outline()) } }
        store.update(tree?.let(adapter::adaptRoot))
    }

    // MARK: From composeui

    override fun invokeVoid(id: Long) = perform(id, null)

    override fun invokeBool(id: Long, value: Boolean) = perform(id, IRValue.Bool(value))

    override fun invokeDouble(id: Long, value: Double) = perform(id, IRValue.Dbl(value))

    override fun invokeInt(id: Long, value: Int) = perform(id, IRValue.Int(value.toLong()))

    override fun invokeString(id: Long, value: String) = perform(id, IRValue.Str(value))

    override fun itemNode(id: Long, index: Int): ViewNode? {
        val bytes = events.row(id, index)
        if (bytes.isEmpty()) return null
        val row = try {
            RenderCodec.decode(bytes)
        } catch (error: RenderDecodingException) {
            log("the app sent a row this player can't read: ${error.message}")
            return null
        }
        trace?.invoke("row $index of ${IRAdapter.idString(id)}:\n" + row.outline())
        return adapter.adaptRow(id, adapter.revision(id), row)
    }

    private fun perform(id: Long, value: IRValue?) {
        val action = adapter.callbacks[id]
        if (action == null) {
            log("callback $id is gone")
            return
        }
        perform(action, value)
    }

    private fun perform(action: Action, value: IRValue?) {
        when (action) {
            is Action.Tap -> send(action.node, RenderEventKind.TAP, null)
            is Action.Submit -> send(action.node, RenderEventKind.SUBMIT, null)
            is Action.Refresh -> send(action.node, RenderEventKind.REFRESH, null)
            is Action.Change -> value?.let { send(action.node, RenderEventKind.CHANGE, it) }
            is Action.ChangeInt -> {
                val index = when (value) {
                    is IRValue.Str -> value.value.toLongOrNull()
                    is IRValue.Int -> value.value
                    else -> null
                }
                index?.let { send(action.node, RenderEventKind.CHANGE, IRValue.Int(it)) }
            }
            is Action.ChangeTo -> send(action.node, RenderEventKind.CHANGE, action.value)
            is Action.ChangeDate -> value.double?.let { send(action.node, RenderEventKind.CHANGE, IRValue.Dbl(it / 1000)) }
            is Action.Focus -> value.bool?.let { send(action.node, RenderEventKind.FOCUS, IRValue.Bool(it)) }
            is Action.Pop -> send(action.node, RenderEventKind.POP, IRValue.Int(action.levels.toLong()))
            is Action.Sequence -> action.actions.forEach { perform(it, value) }
        }
    }

    private fun send(node: Long, kind: Int, value: IRValue?) {
        events.event(node, kind, value?.let(RenderCodec::encodePayload) ?: ByteArray(0))
    }
}
