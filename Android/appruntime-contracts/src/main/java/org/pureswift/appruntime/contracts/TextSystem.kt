package org.pureswift.appruntime.contracts

import android.content.Context
import android.content.MutableContextWrapper
import android.graphics.Typeface
import android.os.Build
import android.text.Editable
import android.text.InputFilter
import android.text.InputType
import android.text.Spanned
import android.text.TextWatcher
import android.text.method.KeyListener
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout

/**
 * The `TextStorage` contract's Android side (Documentation/Plan.md §6.16):
 * an `EditText` per text, made off screen, whose `Editable` is the text.
 *
 * Swift's `EditTextEngine` does what the contract asks and keeps the undo
 * history, since `EditText` has none an app can call. This reads and
 * changes the text, and reports through [TextNatives] what the user does
 * to it: each edit, with what it removed and what it put in, and the
 * selection. The changes Swift asks for aren't reported: Swift knows them.
 * The player's [TextEditorView] shows a text where a `TextEditor` node
 * names it. Main thread only.
 */
class TextSystem {

    fun make(id: Int) {
        texts[id] = HostText(id)
    }

    fun destroy(id: Int) {
        texts.remove(id)?.destroy()
    }

    fun length(id: Int): Int = texts[id]?.editable?.length ?: 0

    fun text(id: Int, start: Int, end: Int): String {
        val editable = texts[id]?.editable ?: return ""
        val from = start.coerceIn(0, editable.length)
        return editable.subSequence(from, end.coerceIn(from, editable.length)).toString()
    }

    /** At least 1: lines end at `\n`. */
    fun lineCount(id: Int): Int {
        val editable = texts[id]?.editable ?: return 1
        var count = 1
        for (index in 0 until editable.length) {
            if (editable[index] == '\n') count++
        }
        return count
    }

    /** The line `location` is on, from 0. */
    fun line(id: Int, location: Int): Int {
        val editable = texts[id]?.editable ?: return 0
        var line = 0
        for (index in 0 until location.coerceIn(0, editable.length)) {
            if (editable[index] == '\n') line++
        }
        return line
    }

    /** Where `line` starts, or -1 past the last. */
    fun lineStart(id: Int, line: Int): Int {
        val editable = texts[id]?.editable ?: return -1
        if (line < 0) return -1
        if (line == 0) return 0
        var seen = 0
        for (index in 0 until editable.length) {
            if (editable[index] == '\n' && ++seen == line) return index + 1
        }
        return -1
    }

    /** A new text, with the caret at the start. */
    fun setText(id: Int, text: String) {
        texts[id]?.guest { view ->
            view.setText(text)
            view.setSelection(0)
        }
    }

    fun replace(id: Int, start: Int, end: Int, text: String) {
        texts[id]?.guest { view -> view.text.replace(start, end, text) }
    }

    fun selectionStart(id: Int): Int = texts[id]?.view?.selectionStart?.coerceAtLeast(0) ?: 0

    fun selectionEnd(id: Int): Int = texts[id]?.view?.selectionEnd?.coerceAtLeast(0) ?: 0

    fun select(id: Int, start: Int, end: Int) {
        texts[id]?.guest { view -> view.setSelection(start, end) }
    }

    /** Scrolls the range into view, once the text is laid out where it's shown. */
    fun reveal(id: Int, start: Int, end: Int) {
        val view = texts[id]?.view ?: return
        view.post {
            view.bringPointIntoView(end)
            view.bringPointIntoView(start)
        }
    }

    internal companion object {
        /** Every text, by the identifier its `TextEditor` node carries. */
        val texts = HashMap<Int, HostText>()
    }
}

/** One text: its `EditText`, and what it's told Swift of the change being made. */
internal class HostText(val id: Int) {

    /** Lets the view's context follow the Activity, for its menus and the keyboard. */
    private val context = MutableContextWrapper(HostContext.application)

    var view: EditorText? = EditorText(context)
        private set

    val editable: Editable? get() = view?.text

    /** The view's own key listener, for when it's editable again. */
    val keys: KeyListener?

    /** While Swift's own change is applied: nothing is reported. */
    private var isGuest = false

    /** The user's change being made: where, and what it removes and puts in. */
    private var changing = false
    private var location = 0
    private var removed = ""
    private var inserted = ""

    /** The selection moved during the change, and is told after it. */
    private var selectionMoved = false

    init {
        val view = view!!
        view.background = null
        view.gravity = Gravity.TOP or Gravity.START
        view.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        view.filters = arrayOf(LineBreaks)
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
        keys = view.keyListener
        view.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(text: CharSequence, start: Int, count: Int, after: Int) {
                if (isGuest) return
                changing = true
                location = start
                removed = text.subSequence(start, start + count).toString()
            }

            override fun onTextChanged(text: CharSequence, start: Int, before: Int, count: Int) {
                if (isGuest || !changing) return
                inserted = text.subSequence(start, start + count).toString()
            }

            override fun afterTextChanged(text: Editable) {
                if (isGuest || !changing) return
                changing = false
                val edit = Triple(location, removed, inserted)
                removed = ""
                inserted = ""
                TextNatives.edited(id, edit.first, edit.second, edit.third)
                if (selectionMoved) {
                    selectionMoved = false
                    TextNatives.selected(id)
                }
            }
        })
        view.host = this
    }

    /** Applies Swift's change to the view, unreported. */
    fun guest(change: (EditorText) -> Unit) {
        val view = view ?: return
        isGuest = true
        try {
            change(view)
        } finally {
            isGuest = false
        }
    }

    fun selectionChanged() {
        if (isGuest) return
        if (changing) {
            selectionMoved = true
            return
        }
        TextNatives.selected(id)
    }

    fun attach(activity: Context) {
        context.baseContext = activity
    }

    fun destroy() {
        val view = view ?: return
        this.view = null
        view.host = null
        (view.parent as? ViewGroup)?.removeView(view)
    }

    /** What the user puts in, with `\n` for its line breaks, as the text holds them. */
    private object LineBreaks : InputFilter {
        override fun filter(source: CharSequence, start: Int, end: Int, dest: Spanned, dstart: Int, dend: Int): CharSequence? {
            if ((start until end).none { source[it] == '\r' }) return null
            return source.subSequence(start, end).toString().replace("\r\n", "\n").replace('\r', '\n')
        }
    }
}

/** A text's `EditText`: it says when its selection moves. */
internal class EditorText(context: Context) : EditText(context) {

    /** Set once the view is made: `EditText` reports a selection while it's being made. */
    var host: HostText? = null

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
        super.onSelectionChanged(selStart, selEnd)
        host?.selectionChanged()
    }
}

/**
 * Where a `TextEditor` node shows the text it names: that text's
 * `EditText`, taking the frame's space. When the node goes, the text
 * leaves the view and stays as it was.
 *
 * It also keeps the node's focus (Documentation/RenderIR.md, Text input):
 * it gives the text the keyboard, or takes it away, only when the node's
 * `focused` differs from what was last rendered or reported, and reports
 * when the user moves the keyboard into the text or out of it.
 */
class TextEditorView(context: Context) : FrameLayout(context) {

    /** The text shown: the node's `buffer` prop, or 0 for none. */
    var text: Int = 0
        set(value) {
            if (value == field) return
            release()
            field = value
            show()
        }

    /** Tells the node's `focus`. */
    var onFocus: ((Boolean) -> Unit)? = null

    /** Focus as last rendered or reported; `null` before either. */
    private var focus: Boolean? = null

    private var configured: Configuration? = null

    init {
        // What takes the focus when the text gives it up, so that Android
        // doesn't hand it to the first text it finds, which may be this one.
        isFocusableInTouchMode = true
        descendantFocusability = FOCUS_BEFORE_DESCENDANTS
    }

    private val editor: EditorText? get() = TextSystem.texts[text]?.view

    private fun show() {
        val host = TextSystem.texts[text] ?: return
        val view = host.view ?: return
        (view.parent as? ViewGroup)?.removeView(view)
        host.attach(context)
        addView(view, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        view.setOnFocusChangeListener { _, focused -> focusChanged(focused) }
        configured?.let { apply(view, it) }
    }

    private fun release() {
        val view = editor ?: return
        if (view.parent !== this) return
        view.onFocusChangeListener = null
        if (view.hasFocus()) {
            hideKeyboard(view)
        }
        removeView(view)
    }

    // MARK: How it looks, and its keyboard

    /**
     * The node's props, and what it inherits: `capitalization` is
     * `never`, `words`, `sentences` or `characters`, or `null` for the
     * platform's way; `design` is SwiftUI's font design.
     */
    data class Configuration(
        val editable: Boolean,
        val wraps: Boolean,
        val autocorrects: Boolean,
        val capitalization: String?,
        val size: Float,
        val bold: Boolean,
        val design: String?,
        val color: Int,
        val tint: Int?,
    )

    fun configure(configuration: Configuration) {
        if (configuration == configured) return
        configured = configuration
        editor?.let { apply(it, configuration) }
    }

    private fun apply(view: EditorText, configuration: Configuration) {
        var type = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        type = type or if (configuration.autocorrects) InputType.TYPE_TEXT_FLAG_AUTO_CORRECT else InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        type = type or when (configuration.capitalization) {
            "words" -> InputType.TYPE_TEXT_FLAG_CAP_WORDS
            "sentences" -> InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            "characters" -> InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS
            else -> 0
        }
        val host = TextSystem.texts[text]
        if (configuration.editable) {
            if (view.keyListener == null) view.keyListener = host?.keys
            view.showSoftInputOnFocus = true
            if (view.inputType != type) {
                view.setRawInputType(type)
                if (view.hasFocus()) inputMethods(view)?.restartInput(view)
            }
        } else {
            // Selects and scrolls; no keyboard.
            view.keyListener = null
            view.showSoftInputOnFocus = false
        }
        view.setHorizontallyScrolling(!configuration.wraps)
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, configuration.size)
        val family = when (configuration.design) {
            "monospaced" -> Typeface.MONOSPACE
            "serif" -> Typeface.SERIF
            else -> Typeface.DEFAULT
        }
        view.typeface = Typeface.create(family, if (configuration.bold) Typeface.BOLD else Typeface.NORMAL)
        view.setTextColor(configuration.color)
        configuration.tint?.let { tint ->
            // The selection in the tint, faded so the text shows through.
            view.highlightColor = (tint and 0x00FFFFFF) or 0x66000000
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                view.textCursorDrawable?.setTint(tint)
            }
        }
    }

    // MARK: Focus

    /** The node's `focused`, or `null` when it has none. */
    fun focus(value: Boolean?) {
        if (value == null || value == focus) return
        focus = value
        val view = editor ?: return
        if (value) {
            // Once it's on screen, if it's only now appearing.
            view.post {
                if (view.parent !== this || focus != true) return@post
                view.requestFocus()
                inputMethods(view)?.showSoftInput(view, InputMethodManager.SHOW_IMPLICIT)
            }
        } else if (view.hasFocus()) {
            requestFocus()
            hideKeyboard(view)
        }
    }

    private fun focusChanged(focused: Boolean) {
        if (focused == focus) return
        focus = focused
        onFocus?.invoke(focused)
    }

    private fun hideKeyboard(view: EditorText) {
        inputMethods(view)?.hideSoftInputFromWindow(view.windowToken, 0)
    }

    private fun inputMethods(view: EditorText): InputMethodManager? =
        view.context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
}

/** What the user does to the texts, for Swift's `TextHub`, on the main thread. */
object TextNatives {

    /** The user's edit: `removed` at `location` became `inserted`. */
    external fun edited(id: Int, location: Int, removed: String, inserted: String)

    /** The selection moved, by the user's hand or the view's. */
    external fun selected(id: Int)
}
