package org.pureswift.appruntime.ui

import com.pureswift.swiftui.ViewNode
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.long
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The adapter from the guest's tree to composeui's, and the events
 * composeui's callbacks become, with no emulator.
 */
class IRAdapterTests {

    /** Records the events the surface sends, and serves rows. */
    class Events : RenderEvents {
        val sent = ArrayList<Triple<Long, Int, IRValue?>>()
        val rows = HashMap<Pair<Long, Int>, IRNode>()

        override fun event(node: Long, kind: Int, payload: ByteArray) {
            sent += Triple(node, kind, if (payload.isEmpty()) null else RenderCodec.decodePayload(payload))
        }

        override fun row(list: Long, index: Int): ByteArray =
            rows[list to index]?.let(TreeEncoder::encode) ?: ByteArray(0)
    }

    private val events = Events()
    private val surface = RenderSurface(events).also { it.log = {} }

    private fun show(tree: IRNode): ViewNode {
        surface.apply(TreeEncoder.encode(tree))
        return surface.store.root!!
    }

    private fun ViewNode.find(id: String): ViewNode? =
        if (this.id == id) this else children.firstNotNullOfOrNull { it.find(id) }

    private fun ViewNode.callback(key: String): Long = (props[key] as JsonPrimitive).long

    private fun text(id: Long, text: String) = IRNode("Text", id, mapOf("text" to IRValue.Str(text)))

    private fun button(id: Long, title: String, role: String? = null) = IRNode(
        "Button", id, role?.let { mapOf("role" to IRValue.Str(it)) } ?: emptyMap(), children = listOf(text(id + 1000, title)),
    )

    @Test
    fun turnsTapsAndChangesIntoEvents() {
        val root = show(IRNode("VStack", 1, children = listOf(
            button(2, "+"),
            IRNode("Toggle", 3, mapOf("isOn" to IRValue.Bool(false)), children = listOf(text(4, "On"))),
            IRNode("TextField", 5, mapOf("text" to IRValue.Str("World"), "placeholder" to IRValue.Str("Name"))),
            IRNode("Slider", 6, mapOf("value" to IRValue.Dbl(0.5), "min" to IRValue.Dbl(0.0), "max" to IRValue.Dbl(1.0))),
        )))
        surface.invokeVoid(root.find("2")!!.callback("onTap"))
        surface.invokeBool(root.find("3")!!.callback("onChange"), true)
        surface.invokeString(root.find("5")!!.callback("onChange"), "Ada")
        surface.invokeDouble(root.find("6")!!.callback("onChange"), 0.75)
        val submit = root.find("5")!!.modifiers.first { it.kind == "onSubmit" }.args["action"] as JsonPrimitive
        surface.invokeVoid(submit.long)
        assertEquals(listOf(
            Triple(2L, RenderEventKind.TAP, null),
            Triple(3L, RenderEventKind.CHANGE, IRValue.Bool(true)),
            Triple(5L, RenderEventKind.CHANGE, IRValue.Str("Ada")),
            Triple(6L, RenderEventKind.CHANGE, IRValue.Dbl(0.75)),
            Triple(5L, RenderEventKind.SUBMIT, null),
        ), events.sent)
    }

    @Test
    fun namesBundleImagesAsThePackagerDoes() {
        val root = show(IRNode("VStack", 1, children = listOf(
            IRNode("Image", 2, mapOf("name" to IRValue.Str("Star-Filled.png"))),
            IRNode("Image", 3, mapOf("systemName" to IRValue.Str("star"))),
        )))
        assertEquals("rt_star_filled", (root.find("2")!!.props["name"] as JsonPrimitive).content)
        assertEquals("Star-Filled.png", (root.find("2")!!.props["label"] as JsonPrimitive).content)
        assertEquals("star", (root.find("3")!!.props["systemName"] as JsonPrimitive).content)
        assertEquals("rt_logo", drawableName("Logo"))
        assertEquals("rt_my_logo_v2", drawableName("My Logo v2.webp"))
        assertEquals("rt_archive_tar", drawableName("archive.tar"))
    }

    @Test
    fun mapsGridsAndSwipeActionsToComposeuisNodes() {
        val root = show(IRNode("VStack", 1, children = listOf(
            IRNode("Grid", 2, mapOf("horizontal" to IRValue.Str("leading"), "horizontalSpacing" to IRValue.Dbl(16.0)), children = listOf(
                IRNode("GridRow", 3, mapOf("alignment" to IRValue.Str("top")), children = listOf(text(4, "Frontend"), text(5, "DynamicSwiftUI"))),
            )),
            IRNode("SwipeActions", 6, mapOf("edge" to IRValue.Str("trailing"), "allowsFullSwipe" to IRValue.Bool(false)), children = listOf(
                text(7, "Banana"), button(8, "Delete", role = "destructive"),
            )),
        )))
        val grid = root.find("2")!!
        assertEquals("Grid", grid.type)
        assertEquals("leading", (grid.props["horizontal"] as JsonPrimitive).content)
        assertEquals(16.0, (grid.props["horizontalSpacing"] as JsonPrimitive).content.toDouble())
        assertEquals("GridRow", grid.children.single().type)
        assertEquals("top", (grid.children.single().props["alignment"] as JsonPrimitive).content)
        val swipe = root.find("6")!!
        assertEquals("SwipeActions", swipe.type)
        assertEquals("false", (swipe.props["allowsFullSwipe"] as JsonPrimitive).content)
        assertEquals(listOf("Text", "Button"), swipe.children.map { it.type })
        surface.invokeVoid(swipe.children[1].callback("onTap"))
        assertEquals<List<Triple<Long, Int, IRValue?>>>(listOf(Triple(8L, RenderEventKind.TAP, null)), events.sent)
    }

    @Test
    fun mapsAGLSurfaceToTheShellsView() {
        val root = show(IRNode("VStack", 1, children = listOf(
            IRNode("GLSurface", 2, mapOf("surface" to IRValue.Int(7)), modifiers = listOf(
                IRModifier("frame", mapOf("height" to IRValue.Dbl(280.0))),
            )),
        )))
        val node = root.find("2")!!
        assertEquals("Composable", node.type)
        assertEquals(IRAdapter.GL_SURFACE, (node.props["name"] as JsonPrimitive).content)
        assertEquals(7, (node.props["surface"] as JsonPrimitive).content.toInt())
        assertEquals(listOf("frame"), node.modifiers.map { it.kind })
    }

    @Test
    fun putsTextSelectionInTheShellsComposable() {
        val text = IRNode("Text", 2, mapOf("text" to IRValue.Str("42")), listOf(IRModifier("textSelection", mapOf("enabled" to IRValue.Bool(true)))))
        val root = show(IRNode("VStack", 1, children = listOf(text)))
        val wrapper = root.find("2.selection")!!
        assertEquals("Composable", wrapper.type)
        assertEquals(IRAdapter.TEXT_SELECTION, (wrapper.props["name"] as JsonPrimitive).content)
        assertEquals(listOf("2"), wrapper.children.map { it.id })
        assertEquals("Text", wrapper.children[0].type)
        val off = IRNode("Text", 3, mapOf("text" to IRValue.Str("no")), listOf(IRModifier("textSelection", mapOf("enabled" to IRValue.Bool(false)))))
        val disabled = show(IRNode("VStack", 1, children = listOf(off))).find("3.selection")!!
        assertEquals(IRAdapter.NO_TEXT_SELECTION, (disabled.props["name"] as JsonPrimitive).content)
        // Without the modifier, nothing around it.
        val plain = show(IRNode("VStack", 1, children = listOf(IRNode("Text", 4, mapOf("text" to IRValue.Str("x"))))))
        assertEquals(null, plain.find("4.selection"))
    }

    @Test
    fun mapsAVideoPlayerToTheShellsView() {
        val player = IRNode("VideoPlayer", 2, mapOf("player" to IRValue.Int(4), "scaling" to IRValue.Str("fill"), "controls" to IRValue.Str("none")))
        val node = show(IRNode("VStack", 1, children = listOf(player))).find("2")!!
        assertEquals("Composable", node.type)
        assertEquals(IRAdapter.VIDEO_PLAYER, (node.props["name"] as JsonPrimitive).content)
        assertEquals(4, (node.props["player"] as JsonPrimitive).content.toInt())
        assertEquals("fill", (node.props["scaling"] as JsonPrimitive).content)
        assertEquals("none", (node.props["controls"] as JsonPrimitive).content)
        assertEquals(emptyList(), node.children)
        // Without its props, the platform's controls, fitted.
        val plain = show(IRNode("VStack", 1, children = listOf(IRNode("VideoPlayer", 2)))).find("2")!!
        assertEquals("fit", (plain.props["scaling"] as JsonPrimitive).content)
        assertEquals("platform", (plain.props["controls"] as JsonPrimitive).content)
    }

    @Test
    fun mapsAWebViewToTheShellsView() {
        val root = show(IRNode("VStack", 1, children = listOf(IRNode("WebView", 2, mapOf("page" to IRValue.Int(3))))))
        val node = root.find("2")!!
        assertEquals("Composable", node.type)
        assertEquals(IRAdapter.WEB_VIEW, (node.props["name"] as JsonPrimitive).content)
        assertEquals(3, (node.props["page"] as JsonPrimitive).content.toInt())
        assertEquals("true", (node.props["flexible"] as JsonPrimitive).content)
        assertEquals(emptyList(), node.children)
    }

    @Test
    fun keepsCallbackIDsAcrossUpdates() {
        val tree = IRNode("VStack", 1, children = listOf(button(2, "+"), text(3, "0")))
        val first = show(tree)
        val second = show(tree.replacing(3, text(3, "1"))!!)
        assertEquals(first.find("2"), second.find("2"))
        assertNotEquals(first.find("3"), second.find("3"))
        // A button that's gone takes its callback with it.
        val gone = first.find("2")!!.callback("onTap")
        show(IRNode("VStack", 1, children = listOf(text(3, "1"))))
        surface.invokeVoid(gone)
        assertTrue(events.sent.isEmpty())
    }

    @Test
    fun patchesSubtrees() {
        show(IRNode("VStack", 1, children = listOf(text(2, "Hello"), text(3, "0"))))
        surface.replaceSubtree(3, TreeEncoder.encode(text(3, "1")))
        assertEquals(JsonPrimitive("1"), surface.store.root!!.find("3")!!.props["text"])
        // Not on screen: ignored.
        surface.replaceSubtree(9, TreeEncoder.encode(text(9, "?")))
        assertNull(surface.store.root!!.find("9"))
    }

    @Test
    fun tagsPickerOptionsAndSendsIndices() {
        val picker = show(IRNode("Picker", 1, mapOf("title" to IRValue.Str("Favorite"), "selection" to IRValue.Int(1), "style" to IRValue.Str("segmented")),
            children = listOf(text(2, "Apple"), text(3, "Banana"))))
        assertEquals(JsonPrimitive("1"), picker.props["selection"])
        assertEquals(listOf("0", "1"), picker.children.map { (it.modifiers.last().args["value"] as JsonPrimitive).content })
        assertTrue(picker.modifiers.any { it.kind == "pickerStyle" })
        surface.invokeString(picker.callback("onChange"), "0")
        assertEquals(Triple(1L, RenderEventKind.CHANGE, IRValue.Int(0)), events.sent.single())
    }

    @Test
    fun flattensNavigationLevels() {
        val nav = show(IRNode("NavStack", 1, children = listOf(
            IRNode("NavLevel", 2, mapOf("title" to IRValue.Str("Example")), children = listOf(
                IRNode("Searchable", 3, mapOf("text" to IRValue.Str(""), "prompt" to IRValue.Str("Fruit")), children = listOf(text(4, "Root"))),
                IRNode("ToolbarItem", 5, mapOf("placement" to IRValue.Str("primaryAction")), children = listOf(button(6, "Add"))),
            )),
            IRNode("NavLevel", 7, mapOf("title" to IRValue.Str("Banana")), children = listOf(text(8, "Detail"))),
        )))
        assertEquals("NavStack", nav.type)
        assertEquals(JsonArray(listOf(JsonPrimitive("Example"), JsonPrimitive("Banana"))), nav.props["titles"])
        assertEquals(listOf("2", "7"), nav.children.map { it.id })
        val toolbar = nav.find("5")!!
        assertEquals(JsonPrimitive("navigationBarTrailing"), toolbar.props["placement"])
        val searches = nav.props["searches"] as JsonArray
        assertEquals(JsonPrimitive("Fruit"), (searches[0] as JsonArray)[2])
        assertEquals(JsonArray(emptyList()), searches[1])

        surface.invokeVoid(nav.callback("onPop"))
        surface.invokeString(((searches[0] as JsonArray)[1] as JsonPrimitive).long, "Ba")
        assertTrue(surface.goBack())
        assertEquals(listOf<Triple<Long, Int, IRValue?>>(
            Triple(1L, RenderEventKind.POP, IRValue.Int(1)),
            Triple(3L, RenderEventKind.CHANGE, IRValue.Str("Ba")),
            Triple(1L, RenderEventKind.POP, IRValue.Int(1)),
        ), events.sent)
    }

    @Test
    fun liftsPresentedAlertsOntoTheScreen() {
        val alert = IRNode("Alert", 3, mapOf("title" to IRValue.Str("Reset the count?"), "isPresented" to IRValue.Bool(true), "message" to IRValue.Str("It goes back to zero.")),
            children = listOf(button(4, "Reset"), button(5, "Reset", "destructive"), button(6, "Cancel", "cancel")))
        val nav = show(IRNode("NavStack", 1, children = listOf(IRNode("NavLevel", 2, children = listOf(alert)))))
        val screen = nav.children.single()
        // The presenting view stays where it was; the alert joins the screen.
        assertEquals("Button", screen.children[0].type)
        val lifted = screen.children.single { it.type == "Alert" }
        val buttons = lifted.props["buttons"] as JsonArray
        assertEquals(2, buttons.size)
        surface.invokeVoid(((buttons[0] as JsonArray)[2] as JsonPrimitive).long)
        surface.invokeVoid(lifted.callback("onDismiss"))
        assertEquals(listOf<Triple<Long, Int, IRValue?>>(
            Triple(5L, RenderEventKind.TAP, null),
            Triple(3L, RenderEventKind.CHANGE, IRValue.Bool(false)),
            Triple(3L, RenderEventKind.CHANGE, IRValue.Bool(false)),
        ), events.sent)

        // Not presented: nothing to lift.
        val closed = show(IRNode("NavStack", 1, children = listOf(IRNode("NavLevel", 2, children = listOf(
            alert.copy(props = alert.props + ("isPresented" to IRValue.Bool(false))))))))
        assertTrue(closed.children.single().children.none { it.type == "Alert" })
    }

    @Test
    fun givesASheetAScreenWithoutANavStack() {
        val root = show(IRNode("Sheet", 1, mapOf("isPresented" to IRValue.Bool(true)), children = listOf(button(2, "About"), text(3, "Sheet"))))
        assertEquals("NavStack", root.type)
        val sheet = root.children.single().children.single { it.type == "Sheet" }
        assertEquals("3", sheet.children.single().children.single().id)
        surface.invokeVoid(sheet.callback("onDismiss"))
        assertEquals(Triple(1L, RenderEventKind.CHANGE, IRValue.Bool(false)), events.sent.single())
    }

    @Test
    fun fetchesLazyRows() {
        val list = show(IRNode("List", 1, mapOf("revision" to IRValue.Int(4)), count = 2))
        assertEquals(2, list.count)
        assertEquals(1L, list.callback("itemProvider"))
        events.rows[1L to 1] = IRNode("NavigationLink", 10, children = listOf(text(11, "Banana")))
        val row = surface.itemNode(1, 1)!!
        assertEquals("10", row.id)
        surface.invokeVoid(row.callback("onTap"))
        assertEquals(Triple(10L, RenderEventKind.TAP, null), events.sent.single())
        assertNull(surface.itemNode(1, 5))
        // The row's callback lives while the list keeps its revision.
        show(IRNode("List", 1, mapOf("revision" to IRValue.Int(4)), count = 2))
        surface.invokeVoid(row.callback("onTap"))
        assertEquals(2, events.sent.size)
    }

    @Test
    fun mapsStepperValuesAndColors() {
        val stepper = show(IRNode("Stepper", 1, mapOf("value" to IRValue.Int(10), "min" to IRValue.Int(0), "max" to IRValue.Int(10), "step" to IRValue.Int(5)),
            modifiers = listOf(IRModifier("foregroundColor", mapOf("color" to IRValue.Arr(listOf(IRValue.Str("red"), IRValue.Dbl(0.5))))))))
        surface.invokeVoid(stepper.callback("onIncrement"))
        surface.invokeVoid(stepper.callback("onDecrement"))
        assertEquals(listOf(IRValue.Int(10), IRValue.Int(5)), events.sent.map { it.third })
        val color = stepper.modifiers.first { it.kind == "foregroundColor" }.args["color"] as JsonPrimitive
        assertEquals(0x7FFF3B30L, color.long)
        assertEquals(0xFF0A84FFL, IRAdapter(dark = true).color(IRValue.Str("blue")))
        assertEquals(0x12345678L, surface.adapter.color(IRValue.Int(0x12345678)))
    }

    @Test
    fun turnsInfiniteFramesIntoFills() {
        val node = show(IRNode("Color", 1, mapOf("color" to IRValue.Str("red")), modifiers = listOf(
            IRModifier("frame", mapOf("maxWidth" to IRValue.Dbl(Double.POSITIVE_INFINITY), "height" to IRValue.Dbl(60.0),
                "horizontal" to IRValue.Str("center"), "vertical" to IRValue.Str("center"))))))
        val frame = node.modifiers.first { it.kind == "frame" }.args
        assertEquals(JsonPrimitive(true), frame["fillWidth"])
        assertEquals(JsonPrimitive(60.0), frame["height"])
        assertNull(frame["maxWidth"])
        // A color fills its frame: composeui would shrink it to nothing if aligned.
        assertNull(frame["horizontal"])
        val text = show(IRNode("Text", 2, mapOf("text" to IRValue.Str("Hi")), modifiers = listOf(
            IRModifier("frame", mapOf("width" to IRValue.Dbl(100.0), "horizontal" to IRValue.Str("leading"))))))
        assertEquals(JsonPrimitive("leading"), text.modifiers.first { it.kind == "frame" }.args["horizontal"])
    }
}
