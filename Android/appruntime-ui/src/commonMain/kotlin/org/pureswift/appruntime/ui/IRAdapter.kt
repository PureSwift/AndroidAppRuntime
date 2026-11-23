package org.pureswift.appruntime.ui

import com.pureswift.swiftui.ModifierNode
import com.pureswift.swiftui.ViewNode
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * What a composeui callback ID does: the guest event it becomes
 * (Documentation/Plan.md §7.1). composeui calls a `CallbackSink` with IDs it
 * found in node props; the adapter assigns them and keeps this table.
 */
sealed interface Action {
    /** `tap` on `node`. */
    data class Tap(val node: Long) : Action
    /** `submit` on `node`. */
    data class Submit(val node: Long) : Action
    /** `refresh` on `node`. */
    data class Refresh(val node: Long) : Action
    /** `change` with the value composeui reports: bool, string or double. */
    data class Change(val node: Long) : Action
    /** `change` with an int: composeui reports a picker's tag string, or a tab's int. */
    data class ChangeInt(val node: Long) : Action
    /** `change` with a fixed value: a stepper's next value, a dismissal's `false`. */
    data class ChangeTo(val node: Long, val value: IRValue) : Action
    /** `change` with seconds since 1970, from composeui's milliseconds. */
    data class ChangeDate(val node: Long) : Action
    /** `focus` with whether the view now has the keyboard. */
    data class Focus(val node: Long) : Action
    /** `pop` on a `NavStack`: the levels left. */
    data class Pop(val node: Long, val levels: Int) : Action
    /** Several events in order: an alert button's `tap`, then the alert's dismissal. */
    data class Sequence(val actions: List<Action>) : Action
}

/**
 * Callback IDs, stable across updates: the same node and slot keep their ID,
 * so composeui's `@Immutable` nodes stay equal and Compose skips what didn't
 * change.
 *
 * A full tree's entries live until the next full tree drops them. A lazy
 * container's rows are fetched once per revision and cached by Compose, so
 * their entries live as long as that list and revision are on screen.
 */
class CallbackTable {

    private data class Key(val node: Long, val slot: String)

    private class Entry(val id: Long, var action: Action, var owner: Any)

    private val entries = HashMap<Key, Entry>()
    private val byID = HashMap<Long, Entry>()
    private var nextID = 1L

    operator fun get(id: Long): Action? = byID[id]?.action

    val size: Int get() = byID.size

    fun id(node: Long, slot: String, action: Action, owner: Any): Long {
        val key = Key(node, slot)
        val entry = entries[key]
        if (entry != null) {
            entry.action = action
            entry.owner = owner
            return entry.id
        }
        val created = Entry(nextID++, action, owner)
        entries[key] = created
        byID[created.id] = created
        return created.id
    }

    /** Drops entries whose owner isn't `pass` or one of `lists`. */
    fun prune(pass: Any, lists: Set<ListRevision>) {
        val iterator = entries.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next().value
            val owner = entry.owner
            if (owner === pass || (owner is ListRevision && owner in lists)) continue
            iterator.remove()
            byID.remove(entry.id)
        }
    }
}

/** A lazy container at one revision: the owner of its rows' callbacks. */
data class ListRevision(val list: Long, val revision: Long)

/**
 * Builds composeui's tree from the guest's (Documentation/Plan.md §7.2). The
 * node ID becomes composeui's string ID, so Compose identity follows the
 * guest's IDs.
 *
 * Most nodes map one to one, with props renamed and events wired. The rest:
 * - a `NavStack`'s `NavLevel`s become screens, with their toolbar items and
 *   `Searchable` fields lifted out;
 * - a presented `Sheet` or `Alert` is lifted onto its level's screen, where
 *   composeui presents it;
 * - colors become ARGB, from names in light or dark;
 * - `Picker` options get tags.
 */
class IRAdapter(var dark: Boolean = false) {

    val callbacks = CallbackTable()

    /** Types this adapter doesn't know, logged once each. */
    private val unknown = HashSet<String>()

    var log: (String) -> Unit = { println("AppRuntime: $it") }

    private var owner: Any = Any()
    /** The lazy containers in the tree, and their revisions. */
    private var lists = HashMap<Long, Long>()

    /** Presentations lifted onto the screen being built. */
    private var presentations = ArrayList<ViewNode>()
    /** The `Searchable` field of the level being built. */
    private var search: JsonArray? = null
    /** The `Refreshable` wrapping the node being converted. */
    private var refreshable: Long? = null

    /**
     * What the node being converted inherits that composeui doesn't keep:
     * the font's design, and the keyboard's `autocorrection` and
     * `autocapitalization`. A `TextEditor` takes them as props.
     */
    private data class Inherited(val design: String? = null, val autocorrects: Boolean = true, val capitalization: String? = null)

    private var inherited = Inherited()

    /** The whole tree: a new set of callbacks, pruning the last tree's. */
    fun adaptRoot(root: IRNode): ViewNode {
        owner = Any()
        lists = HashMap()
        presentations = ArrayList()
        search = null
        var node = convert(root)
        if (presentations.isNotEmpty() || search != null) {
            // Only a NavStack's screens present; give the app one.
            val searches = JsonArray(listOf(search ?: JsonArray(emptyList())))
            node = navStack("${idString(root.id)}:nav", null, listOf(""), listOf(screen("${idString(root.id)}:screen", listOf(node) + presentations)), searches)
        }
        // A plain button is SwiftUI's default; Material's is filled.
        node = node.copy(modifiers = listOf(ModifierNode("buttonStyle", obj("style" to str("borderless")))) + node.modifiers)
        callbacks.prune(owner, lists.map { (list, revision) -> ListRevision(list, revision) }.toSet())
        return node
    }

    /** The revision of the lazy container `list` in the last tree. */
    fun revision(list: Long): Long = lists[list] ?: 0

    /** Row `row` of the lazy container `list`, at `revision`. */
    fun adaptRow(list: Long, revision: Long, row: IRNode): ViewNode {
        val saved = owner
        val savedPresentations = presentations
        owner = ListRevision(list, revision)
        presentations = ArrayList()
        val node = convert(row)
        owner = saved
        presentations = savedPresentations
        return node
    }

    // MARK: Nodes

    /**
     * A node, in the shell's selection composable when it has
     * `textSelection`: the text inside it can be selected and copied with
     * the platform's menu, or, when it's disabled, can't.
     */
    private fun convert(n: IRNode): ViewNode {
        val saved = inherited
        inherited = inherit(saved, n)
        try {
            return convertSelectable(n)
        } finally {
            inherited = saved
        }
    }

    /** As SwiftUI's environment: the last of a kind on a node is what its subtree sees. */
    private fun inherit(outer: Inherited, n: IRNode): Inherited {
        var result = outer
        for (m in n.modifiers) {
            when (m.kind) {
                // A font replaces the whole font, its design too.
                "font" -> result = result.copy(design = m.args["design"].string)
                "autocorrection" -> result = result.copy(autocorrects = m.args["disabled"].bool != true)
                "autocapitalization" -> result = result.copy(capitalization = m.args["mode"].string)
            }
        }
        return result
    }

    private fun convertSelectable(n: IRNode): ViewNode {
        val converted = convertNode(n)
        val selection = n.modifiers.lastOrNull { it.kind == "textSelection" } ?: return converted
        val name = if (selection.args["enabled"].bool != false) TEXT_SELECTION else NO_TEXT_SELECTION
        return ViewNode("Composable", converted.id + ".selection", obj("name" to str(name)), emptyList(), listOf(converted))
    }

    private fun convertNode(n: IRNode): ViewNode {
        val id = idString(n.id)
        val mods = modifiers(n)
        fun node(type: String, vararg props: Pair<String, JsonElement?>, children: List<ViewNode> = convertAll(n.children), modifiers: List<ModifierNode> = mods, count: Int? = null) =
            ViewNode(type, id, obj(*props), modifiers, children, count)

        return when (n.type) {
            "Text" -> node("Text", "text" to str(n["text"].string ?: ""))
            // A bundle image is the packager's drawable; TalkBack says its own name.
            "Image" -> node(
                "Image",
                "systemName" to n["systemName"].string?.let(::str),
                "name" to n["name"].string?.let { str(drawableName(it)) },
                "label" to n["name"].string?.let(::str),
            )
            "Label" -> node("Label", children = listOf(
                ViewNode("Image", "$id:icon", obj("systemName" to str(n["systemImage"].string ?: ""))),
                ViewNode("Text", "$id:title", obj("text" to str(n["title"].string ?: ""))),
            ))
            "Spacer", "Divider", "Form" -> node(n.type)
            "Color" -> node("Color", "color" to num(color(n["color"]) ?: 0))
            // The shell registers the view a surface draws in (GraphicsView).
            // Like the web view, it takes the space its stack's other
            // children leave, as in SwiftUI (composeui's `flexible`).
            "GLSurface" -> node("Composable", "name" to str(GL_SURFACE), "surface" to num(n["surface"].long ?: 0), "flexible" to bool(true), children = emptyList())
            // The shell registers the view a page shows in (WebPageView).
            "WebView" -> node("Composable", "name" to str(WEB_VIEW), "page" to num(n["page"].long ?: 0), "flexible" to bool(true), children = emptyList())
            // The shell registers the view a text shows in (TextEditorView).
            // It takes the space offered, and scrolls its own content.
            "TextEditor" -> {
                val focused = n.modifiers.lastOrNull { it.kind == "focused" }
                node(
                    "Composable", "name" to str(TEXT_EDITOR), "buffer" to num(n["buffer"].long ?: 0),
                    "editable" to bool(n["editable"].bool ?: true), "wraps" to bool(n["wraps"].bool ?: true),
                    "autocorrects" to bool(inherited.autocorrects), "capitalization" to inherited.capitalization?.let(::str),
                    "design" to inherited.design?.let(::str),
                    "focused" to focused?.let { bool(it.args["value"].bool ?: false) },
                    "onFocus" to focused?.let { num(callback(n, "focus", Action.Focus(n.id))) },
                    "flexible" to bool(true), children = emptyList(),
                )
            }
            // The shell registers the view a camera's preview shows in
            // (CameraPreviewFrame). It takes the space offered.
            "CameraPreview" -> node(
                "Composable", "name" to str(CAMERA_PREVIEW), "camera" to num(n["camera"].long ?: 0),
                "scaling" to str(n["scaling"].string ?: "fill"), "flexible" to bool(true), children = emptyList(),
            )
            // The shell registers what draws a photo from the system's
            // thumbnails. Like the web view, it takes the space offered.
            "Photo" -> node(
                "Composable", "name" to str(PHOTO), "asset" to str(n["asset"].string ?: ""),
                "scaling" to str(n["scaling"].string ?: "fill"), "flexible" to bool(true), children = emptyList(),
            )
            // The shell registers the view a player shows in (PlayerView).
            // Its size is the frame the guest gives it.
            "VideoPlayer" -> node(
                "Composable", "name" to str(VIDEO_PLAYER), "player" to num(n["player"].long ?: 0),
                "scaling" to str(n["scaling"].string ?: "fit"), "controls" to str(n["controls"].string ?: "platform"),
                children = emptyList(),
            )
            "Shape" -> node(
                "Shape",
                "shape" to str(n["shape"].string ?: "rectangle"),
                "cornerRadius" to n["cornerRadius"].double?.let(::num),
                "fill" to num(color(n["fill"]) ?: color(n["stroke"]) ?: color(IRValue.Str("primary")) ?: 0),
            )
            "VStack", "HStack", "LazyVStack", "LazyHStack" -> stack(n, mods)
            "ZStack" -> node("ZStack", "horizontal" to n["horizontal"].string?.let(::str), "vertical" to n["vertical"].string?.let(::str))
            "ScrollView" -> scrollView(n, mods)
            "Button" -> {
                val tint = if (n["role"].string == "destructive") listOf(ModifierNode("tint", obj("color" to num(color(IRValue.Str("red")) ?: 0)))) else emptyList()
                node("Button", "onTap" to num(callback(n, "tap", Action.Tap(n.id))), modifiers = tint + mods)
            }
            "NavigationLink" -> node("NavigationLink", "onTap" to num(callback(n, "tap", Action.Tap(n.id))))
            "Link" -> node("Link", "url" to n["url"].string?.let(::str))
            "Toggle" -> node("Toggle", "isOn" to bool(n["isOn"].bool ?: false), "onChange" to num(callback(n, "change", Action.Change(n.id))))
            "TextField" -> {
                // composeui's `focused`: whether to have the keyboard, and
                // what to tell when the user moves it.
                val focus = n.modifiers.lastOrNull { it.kind == "focused" }?.let {
                    listOf(ModifierNode("focused", obj(
                        "isFocused" to str((it.args["value"].bool ?: false).toString()),
                        "onChange" to num(callback(n, "focus", Action.Focus(n.id))),
                    )))
                } ?: emptyList()
                node(
                    "TextField",
                    "text" to str(n["text"].string ?: ""),
                    "placeholder" to str(n["placeholder"].string ?: ""),
                    "secure" to bool(n["secure"].bool ?: false),
                    "onChange" to num(callback(n, "change", Action.Change(n.id))),
                    modifiers = mods + focus + ModifierNode("onSubmit", obj("action" to num(callback(n, "submit", Action.Submit(n.id))))),
                )
            }
            "Slider" -> node(
                "Slider",
                "value" to num(n["value"].double ?: 0.0),
                "min" to num(n["min"].double ?: 0.0),
                "max" to num(n["max"].double ?: 1.0),
                "onChange" to num(callback(n, "change", Action.Change(n.id))),
            )
            "Stepper" -> {
                val value = n["value"].long ?: 0
                val step = n["step"].long ?: 1
                val min = n["min"].long ?: Long.MIN_VALUE
                val max = n["max"].long ?: Long.MAX_VALUE
                node(
                    "Stepper",
                    "onIncrement" to num(callback(n, "increment", Action.ChangeTo(n.id, IRValue.Int(minOf(value + step, max))))),
                    "onDecrement" to num(callback(n, "decrement", Action.ChangeTo(n.id, IRValue.Int(maxOf(value - step, min))))),
                )
            }
            "ProgressView" -> {
                val value = n["value"].double
                val total = n["total"].double ?: 1.0
                node("ProgressView", "value" to value?.let { num(if (total > 0) it / total else 0.0) })
            }
            "DatePicker" -> node(
                "DatePicker",
                "millis" to num((n["value"].double ?: 0.0) * 1000),
                "onChange" to num(callback(n, "change", Action.ChangeDate(n.id))),
                children = listOf(ViewNode("Text", "$id:title", obj("text" to str(n["title"].string ?: "")))),
            )
            "Picker" -> picker(n, mods)
            "List" -> list(n, mods)
            "Section" -> node("Section", "header" to n["header"].string?.let(::str), "footer" to n["footer"].string?.let(::str))
            "SwipeActions" -> node(
                "SwipeActions",
                "edge" to n["edge"].string?.let(::str),
                "allowsFullSwipe" to n["allowsFullSwipe"].bool?.let { str(it.toString()) },
            )
            "ContextMenu" -> node("ContextMenu", "contentCount" to num(1))
            "DisclosureGroup" -> {
                val expanded = n["isExpanded"].bool ?: false
                node(
                    "DisclosureGroup",
                    "labelCount" to num(1),
                    "isExpanded" to str(expanded.toString()),
                    "onToggle" to num(callback(n, "change", Action.Change(n.id))),
                )
            }
            "LazyVGrid", "LazyHGrid" -> grid(n, mods)
            "Grid" -> node(
                "Grid",
                "horizontal" to n["horizontal"].string?.let(::str),
                "horizontalSpacing" to n["horizontalSpacing"].double?.let(::num),
                "verticalSpacing" to n["verticalSpacing"].double?.let(::num),
            )
            "GridRow" -> node("GridRow", "alignment" to n["alignment"].string?.let(::str))
            "NavStack" -> navigation(n, mods)
            "NavLevel", "Tab" -> node("VStack", "alignment" to str("leading"), "spacing" to num(0.0))
            "ToolbarItem" -> node("HStack")
            "TabView" -> tabs(n, mods)
            "Searchable" -> {
                search = JsonArray(listOf(
                    str(n["text"].string ?: ""),
                    num(callback(n, "change", Action.Change(n.id))),
                    str(n["prompt"].string ?: ""),
                ))
                single(n, mods)
            }
            "Sheet" -> sheet(n, mods)
            "Alert" -> alert(n, mods)
            "Menu" -> node("Menu", "label" to str(n["title"].string ?: ""), children = menuItems(n.children))
            "Refreshable" -> {
                val saved = refreshable
                refreshable = n.id
                val child = single(n, mods)
                refreshable = saved
                child
            }
            else -> {
                if (unknown.add(n.type)) log("no player for ${n.type}; it shows nothing")
                ViewNode("EmptyView", id)
            }
        }
    }

    private fun convertAll(children: List<IRNode>): List<ViewNode> = children.map(::convert)

    /** A wrapper that lays out as its one child: the child, with the wrapper's modifiers first. */
    private fun single(n: IRNode, mods: List<ModifierNode>): ViewNode {
        val child = n.children.firstOrNull()?.let(::convert) ?: return ViewNode("EmptyView", idString(n.id), modifiers = mods)
        return if (mods.isEmpty()) child else child.copy(modifiers = mods + child.modifiers)
    }

    private fun stack(n: IRNode, mods: List<ModifierNode>): ViewNode {
        val props = mutableListOf<Pair<String, JsonElement?>>(
            "alignment" to n["alignment"].string?.let(::str),
            "spacing" to n["spacing"].double?.let(::num),
        )
        if (n.count != null) {
            val revision = n["revision"].long ?: 0
            lists[n.id] = revision
            props += listOf("itemProvider" to num(n.id), "contentVersion" to num(revision))
        }
        var children = convertAll(n.children)
        if (n.type == "HStack") {
            // A text field takes the width its row's other views leave, as in
            // SwiftUI; composeui's fills the row, leaving them none.
            children = children.zip(n.children) { child, original ->
                if (original.type == "TextField") child.copy(props = JsonObject(child.props + ("flexible" to bool(true)))) else child
            }
        }
        return ViewNode(n.type, idString(n.id), obj(*props.toTypedArray()), mods, children, n.count)
    }

    private fun scrollView(n: IRNode, mods: List<ModifierNode>): ViewNode {
        // A grid scrolls itself; inside another scroller Compose can't measure it.
        val lone = n.children.singleOrNull()
        if (lone != null && (lone.type == "LazyVGrid" || lone.type == "LazyHGrid")) {
            val grid = convert(lone)
            return grid.copy(modifiers = mods + grid.modifiers)
        }
        val axis = if (n["axes"].string == "horizontal") "horizontal" else "vertical"
        return ViewNode("ScrollView", idString(n.id), obj("axis" to str(axis)), mods, convertAll(n.children))
    }

    private fun picker(n: IRNode, mods: List<ModifierNode>): ViewNode {
        val options = n.children.mapIndexed { index, option ->
            val converted = convert(option)
            converted.copy(modifiers = converted.modifiers + ModifierNode("tag", obj("value" to str(index.toString()))))
        }
        val style = n["style"].string?.let { listOf(ModifierNode("pickerStyle", obj("style" to str(it)))) } ?: emptyList()
        return ViewNode("Picker", idString(n.id), obj(
            "title" to str(n["title"].string ?: ""),
            // Absent when no option matches: nothing selected.
            "selection" to n["selection"].long?.let { str(it.toString()) },
            "onChange" to num(callback(n, "change", Action.ChangeInt(n.id))),
        ), style + mods, options)
    }

    private fun list(n: IRNode, mods: List<ModifierNode>): ViewNode {
        val id = idString(n.id)
        val onRefresh = refreshable?.let { num(callbacks.id(it, "refresh", Action.Refresh(it), owner)) }
        if (n.count == null) {
            // composeui's List is lazy only; an eager one scrolls like a Form.
            return ViewNode("Form", id, JsonObject(emptyMap()), mods, convertAll(n.children))
        }
        val revision = n["revision"].long ?: 0
        lists[n.id] = revision
        return ViewNode("List", id, obj(
            "itemProvider" to num(n.id),
            "contentVersion" to num(revision),
            "onRefresh" to onRefresh,
        ), mods, emptyList(), n.count)
    }

    private fun grid(n: IRNode, mods: List<ModifierNode>): ViewNode {
        val items = (n["columns"] ?: n["rows"]).array.orEmpty().mapNotNull { it.array }
        val first = items.firstOrNull()
        val adaptive = first?.getOrNull(0).string == "adaptive"
        val spacing = n["spacing"].double ?: first?.getOrNull(3).double ?: 8.0
        val props = mutableListOf<Pair<String, JsonElement?>>(
            "spacing" to num(spacing),
            "adaptiveMin" to if (adaptive) first?.getOrNull(1).double?.let(::num) else null,
            "trackCount" to num(maxOf(items.size, 1)),
        )
        if (n.count != null) {
            // composeui's grids are eager: a lazy one is AppRuntime's own view.
            val revision = n["revision"].long ?: 0
            lists[n.id] = revision
            props += listOf(
                "name" to str(LazyGridView.NAME),
                "vertical" to bool(n.type == "LazyVGrid"),
                "itemProvider" to num(n.id),
                "contentVersion" to num(revision),
                "count" to num(n.count),
            )
            return ViewNode("Composable", idString(n.id), obj(*props.toTypedArray()), mods, emptyList(), n.count)
        }
        return ViewNode(n.type, idString(n.id), obj(*props.toTypedArray()), mods, convertAll(n.children))
    }

    // MARK: Navigation

    private fun navigation(n: IRNode, mods: List<ModifierNode>): ViewNode {
        val titles = ArrayList<String>()
        val screens = ArrayList<ViewNode>()
        val searches = ArrayList<JsonElement>()
        val savedPresentations = presentations
        val savedSearch = search
        for (level in n.children) {
            presentations = ArrayList()
            search = null
            val content = level.children.filter { it.type != "ToolbarItem" }.map(::convert)
            val toolbar = level.children.filter { it.type == "ToolbarItem" }.map { item ->
                ViewNode("ToolbarItem", idString(item.id), obj("placement" to str(placement(item["placement"].string))),
                    modifiers(item), convertAll(item.children))
            }
            titles += level["title"].string ?: ""
            screens += screen(idString(level.id), content + toolbar + presentations, modifiers(level))
            searches.add(search ?: JsonArray(emptyList()))
        }
        presentations = savedPresentations
        search = savedSearch
        val onPop = callback(n, "pop", Action.Pop(n.id, maxOf(n.children.size - 1, 0)))
        return navStack(idString(n.id), onPop, titles, screens, JsonArray(searches), mods)
    }

    private fun navStack(id: String, onPop: Long?, titles: List<String>, screens: List<ViewNode>, searches: JsonArray?, mods: List<ModifierNode> = emptyList()): ViewNode =
        ViewNode("NavStack", id, obj(
            "titles" to JsonArray(titles.map(::str)),
            "onPop" to onPop?.let(::num),
            "searches" to searches,
        ), mods, screens)

    private fun screen(id: String, children: List<ViewNode>, mods: List<ModifierNode> = emptyList()): ViewNode =
        ViewNode("VStack", id, obj("alignment" to str("leading"), "spacing" to num(0.0)), mods, children)

    /** composeui's toolbar placements: leading, trailing, principal and the bottom bar. */
    private fun placement(placement: String?): String = when (placement) {
        "cancellationAction", "navigation" -> "navigationBarLeading"
        "principal" -> "principal"
        "bottomBar" -> "bottomBar"
        else -> "navigationBarTrailing"
    }

    private fun tabs(n: IRNode, mods: List<ModifierNode>): ViewNode {
        val tabs = n.children.map { tab ->
            ViewNode("VStack", idString(tab.id), obj("spacing" to num(0.0)),
                listOf(ModifierNode("tabItem", obj("text" to str(tab["title"].string ?: "")))) + modifiers(tab),
                convertAll(tab.children))
        }
        return ViewNode("TabView", idString(n.id), obj(
            "selection" to num(n["selection"].long ?: 0),
            "onSelect" to num(callback(n, "change", Action.ChangeInt(n.id))),
        ), mods, tabs)
    }

    // MARK: Presentations

    private fun sheet(n: IRNode, mods: List<ModifierNode>): ViewNode {
        val presenting = single(n, mods)
        if (n["isPresented"].bool == true) {
            val id = idString(n.id)
            val content = convertAll(n.children.drop(1))
            presentations += ViewNode("Sheet", "$id:sheet", obj(
                "onDismiss" to num(callback(n, "dismiss", Action.ChangeTo(n.id, IRValue.Bool(false)))),
                "detents" to JsonArray(emptyList()),
            ), emptyList(), listOf(ViewNode("VStack", "$id:content", obj("spacing" to num(0.0)), emptyList(), content)))
        }
        return presenting
    }

    private fun alert(n: IRNode, mods: List<ModifierNode>): ViewNode {
        val presenting = single(n, mods)
        if (n["isPresented"].bool == true) {
            val id = idString(n.id)
            val dismiss = Action.ChangeTo(n.id, IRValue.Bool(false))
            var buttons = n.children.drop(1).filter { it.type == "Button" }.map { button ->
                // An alert's button closes it: the action, then the dismissal.
                val action = Action.Sequence(listOf(Action.Tap(button.id), dismiss))
                JsonArray(listOf(
                    str(label(button)),
                    str(button["role"].string ?: "normal"),
                    num(callbacks.id(button.id, "alert", action, owner)),
                ))
            }
            if (buttons.isEmpty()) {
                buttons = listOf(JsonArray(listOf(str("OK"), str("cancel"), num(callback(n, "ok", dismiss)))))
            }
            val dialog = n["style"].string == "dialog"
            presentations += ViewNode(if (dialog) "ConfirmationDialog" else "Alert", "$id:alert", obj(
                "title" to str(n["title"].string ?: ""),
                "message" to n["message"].string?.let(::str),
                "showsTitle" to str((n["titleVisibility"].string == "visible").toString()),
                "onDismiss" to num(callback(n, "dismiss", dismiss)),
                "buttons" to JsonArray(buttons),
            ))
        }
        return presenting
    }

    /** A menu's items: its buttons, with sections and nested menus flattened. */
    private fun menuItems(children: List<IRNode>): List<ViewNode> = children.flatMap { child ->
        when (child.type) {
            "Button" -> listOf(convert(child))
            "Section", "Menu" -> menuItems(child.children)
            else -> emptyList()
        }
    }

    /** A button's title: its first text. */
    private fun label(n: IRNode): String {
        if (n.type == "Text") return n["text"].string ?: ""
        if (n.type == "Label") return n["title"].string ?: ""
        for (child in n.children) {
            val label = label(child)
            if (label.isNotEmpty()) return label
        }
        return ""
    }

    // MARK: Modifiers

    private fun modifiers(n: IRNode): List<ModifierNode> {
        if (n.modifiers.isEmpty()) return emptyList()
        val result = ArrayList<ModifierNode>(n.modifiers.size)
        for (m in n.modifiers) {
            val a = m.args
            when (m.kind) {
                "padding", "offset", "cornerRadius" -> result += ModifierNode(m.kind, numbers(a))
                "frame" -> result += frame(a, fills = n.type == "Color" || n.type == "Shape")
                "background" -> color(a["color"])?.let { result += ModifierNode("background", obj("color" to num(it))) }
                "foregroundColor", "tint" -> color(a["color"])?.let { result += ModifierNode(m.kind, obj("color" to num(it))) }
                "opacity" -> result += ModifierNode("opacity", obj("opacity" to num(a["value"].double ?: 1.0)))
                "border" -> result += ModifierNode("border", obj("color" to color(a["color"])?.let(::num), "width" to num(a["width"].double ?: 1.0)))
                "shadow" -> result += ModifierNode("shadow", obj("radius" to num(a["radius"].double ?: 0.0)))
                "font" -> {
                    result += ModifierNode("font", obj(
                        "style" to a["style"].string?.let(::str),
                        "size" to a["size"].double?.let(::num),
                        "weight" to a["weight"].string?.let(::str),
                    ))
                    if (a["italic"].bool == true) result += ModifierNode("italic")
                }
                "fontWeight" -> result += ModifierNode("fontWeight", obj("weight" to a["weight"].string?.let(::str)))
                "italic" -> if (a["value"].bool != false) result += ModifierNode("italic")
                "lineLimit" -> result += ModifierNode("lineLimit", obj("count" to a["lines"].long?.let(::num)))
                "multilineTextAlignment" -> result += ModifierNode("multilineTextAlignment", obj("value" to a["alignment"].string?.let(::str)))
                "disabled" -> result += ModifierNode("disabled", obj("value" to bool(a["value"].bool ?: true)))
                "onTapGesture" -> result += ModifierNode("onTapGesture", obj("action" to num(callback(n, "tapGesture", Action.Tap(n.id)))))
                "accessibilityLabel" -> result += ModifierNode("accessibilityLabel", obj("text" to a["text"].string?.let(::str)))
                "accessibilityIdentifier" -> result += ModifierNode("accessibilityIdentifier", obj("id" to a["identifier"].string?.let(::str)))
            }
        }
        return result
    }

    /**
     * ∞ in a maximum means "fill the space offered". A view that fills its
     * frame (a color, a shape) drops the frame's alignment: composeui wraps
     * aligned content to its own size, and a color has none.
     */
    private fun frame(a: Map<String, IRValue>, fills: Boolean): ModifierNode {
        val props = ArrayList<Pair<String, JsonElement?>>()
        for (key in listOf("width", "height", "minWidth", "maxWidth", "minHeight", "maxHeight")) {
            val value = a[key].double ?: continue
            when {
                key == "maxWidth" && value.isInfinite() -> props += "fillWidth" to bool(true)
                key == "maxHeight" && value.isInfinite() -> props += "fillHeight" to bool(true)
                value.isFinite() -> props += key to num(value)
            }
        }
        if (!fills) {
            props += "horizontal" to a["horizontal"].string?.let(::str)
            props += "vertical" to a["vertical"].string?.let(::str)
        }
        return ModifierNode("frame", obj(*props.toTypedArray()))
    }

    private fun numbers(a: Map<String, IRValue>): JsonObject =
        JsonObject(a.mapNotNull { (key, value) -> value.double?.let { key to num(it) } }.toMap())

    // MARK: Colors

    /** A color prop as ARGB: a name, `[name, opacity]`, or a fixed `0xAARRGGBB`. */
    fun color(value: IRValue?): Long? = when (value) {
        is IRValue.Str -> named(value.value)
        is IRValue.Int -> value.value and 0xFFFFFFFFL
        is IRValue.Arr -> {
            val base = value.values.getOrNull(0).string?.let(::named)
            val opacity = value.values.getOrNull(1).double ?: 1.0
            base?.let {
                val alpha = (((it ushr 24) and 0xFF) * opacity.coerceIn(0.0, 1.0)).toLong()
                (alpha shl 24) or (it and 0xFFFFFFL)
            }
        }
        else -> null
    }

    private fun named(name: String): Long? = (if (dark) DARK else LIGHT)[name]

    // MARK: Helpers

    private fun callback(n: IRNode, slot: String, action: Action): Long = callbacks.id(n.id, slot, action, owner)

    companion object {

        /** The registered composable a `GLSurface` node becomes. */
        const val GL_SURFACE = "org.pureswift.appruntime.GLSurface"

        /** The registered composable a `WebView` node becomes. */
        const val WEB_VIEW = "org.pureswift.appruntime.WebView"

        /** The registered composables a node with `textSelection` is in. */
        const val TEXT_SELECTION = "org.pureswift.appruntime.TextSelection"
        const val NO_TEXT_SELECTION = "org.pureswift.appruntime.NoTextSelection"

        /** The registered composable a `TextEditor` node becomes. */
        const val TEXT_EDITOR = "org.pureswift.appruntime.TextEditor"

        /** The registered composable a `CameraPreview` node becomes. */
        const val CAMERA_PREVIEW = "org.pureswift.appruntime.CameraPreview"

        /** The registered composable a `Photo` node becomes. */
        const val PHOTO = "org.pureswift.appruntime.Photo"

        /** The registered composable a `VideoPlayer` node becomes. */
        const val VIDEO_PLAYER = "org.pureswift.appruntime.VideoPlayer"

        /** The node ID as composeui's string ID: the u64, in decimal. */
        fun idString(id: Long): String = id.toULong().toString()

        // The platform colors, light and dark: iOS's system colors, so apps
        // look alike on every host.
        val LIGHT: Map<String, Long> = mapOf(
            "primary" to 0xFF000000, "secondary" to 0x993C3C43, "accentColor" to 0xFF007AFF,
            "clear" to 0x00000000, "black" to 0xFF000000, "white" to 0xFFFFFFFF, "gray" to 0xFF8E8E93,
            "red" to 0xFFFF3B30, "orange" to 0xFFFF9500, "yellow" to 0xFFFFCC00, "green" to 0xFF34C759,
            "mint" to 0xFF00C7BE, "teal" to 0xFF30B0C7, "cyan" to 0xFF32ADE6, "blue" to 0xFF007AFF,
            "indigo" to 0xFF5856D6, "purple" to 0xFFAF52DE, "pink" to 0xFFFF2D55, "brown" to 0xFFA2845E,
        )

        val DARK: Map<String, Long> = LIGHT + mapOf(
            "primary" to 0xFFFFFFFF, "secondary" to 0x99EBEBF5, "accentColor" to 0xFF0A84FF,
            "red" to 0xFFFF453A, "orange" to 0xFFFF9F0A, "yellow" to 0xFFFFD60A, "green" to 0xFF30D158,
            "mint" to 0xFF63E6E2, "teal" to 0xFF40C8E0, "cyan" to 0xFF64D2FF, "blue" to 0xFF0A84FF,
            "indigo" to 0xFF5E5CE6, "purple" to 0xFFBF5AF2, "pink" to 0xFFFF375F, "brown" to 0xFFAC8E68,
        )
    }
}

internal fun str(value: String) = JsonPrimitive(value)
internal fun num(value: Number) = JsonPrimitive(value)
internal fun bool(value: Boolean) = JsonPrimitive(value)

/** Props without the absent ones. */
internal fun obj(vararg props: Pair<String, JsonElement?>): JsonObject =
    JsonObject(props.mapNotNull { (key, value) -> value?.let { key to it } }.toMap())

/**
 * The drawable the packager makes of a bundle image (Swift's
 * `ImageResources.resourceName`): `rt_`, then the name without its image
 * extension, lowercased, with anything but `[a-z0-9_]` as `_`.
 */
fun drawableName(name: String): String {
    val extensions = setOf("png", "jpg", "jpeg", "webp", "gif")
    val dot = name.lastIndexOf('.')
    val base = if (dot > 0 && name.substring(dot + 1).lowercase() in extensions) name.substring(0, dot) else name
    return "rt_" + base.lowercase().map { if (it in 'a'..'z' || it in '0'..'9' || it == '_') it else '_' }.joinToString("")
}
