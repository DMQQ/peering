package pl.dmq.peering.ui.wiring

import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import pl.dmq.peering.feature.remote.Macro
import pl.dmq.peering.feature.remote.MacroCodec
import pl.dmq.peering.feature.remote.MacroStore

/** [MacroStore] over one SharedPreferences file. */
internal class PreferencesMacroStore(private val preferences: SharedPreferences) : MacroStore {
    private val macros = MutableStateFlow(MacroCodec.decode(preferences.getString(KEY, "").orEmpty()))

    override val custom: StateFlow<List<Macro>> = macros.asStateFlow()

    override fun add(macro: Macro): Boolean = save(macros.value + macro)

    override fun remove(id: String): Boolean = save(macros.value.filterNot { it.id == id })

    private fun save(next: List<Macro>): Boolean {
        val saved = preferences.edit().putString(KEY, MacroCodec.encode(next)).commit()
        if (saved) macros.value = next
        return saved
    }

    private companion object {
        const val KEY = "custom_macros"
    }
}
