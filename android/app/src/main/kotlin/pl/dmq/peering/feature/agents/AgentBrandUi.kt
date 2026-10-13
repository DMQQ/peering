package pl.dmq.peering.feature.agents

import androidx.compose.ui.graphics.vector.ImageVector
import pl.dmq.peering.R
import pl.dmq.peering.feature.terminal.TerminalGlyphs
import pl.dmq.peering.ui.kit.AppIcons

fun AgentBrand.icon(): ImageVector = when (this) {
    AgentBrand.CLAUDE -> AppIcons.sparkles
    AgentBrand.CODEX -> AppIcons.code
    AgentBrand.OPENCODE -> TerminalGlyphs.terminal
    AgentBrand.OTHER -> AppIcons.computer
}

fun AgentBrand.taglineRes(): Int = when (this) {
    AgentBrand.CLAUDE -> R.string.agents_tagline_claude
    AgentBrand.CODEX -> R.string.agents_tagline_codex
    AgentBrand.OPENCODE -> R.string.agents_tagline_opencode
    AgentBrand.OTHER -> R.string.agents_tagline_other
}
