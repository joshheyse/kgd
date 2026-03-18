package com.kgd.client

/**
 * RGB color with 16-bit per channel precision.
 */
data class Color(
    val r: Int = 0,
    val g: Int = 0,
    val b: Int = 0,
)

/**
 * Describes a logical position for a placement.
 *
 * Use the factory methods [Anchor.absolute], [Anchor.pane], and [Anchor.nvimWin]
 * to construct the appropriate variant.
 */
sealed class Anchor {

    /** Serialize to a dict, omitting zero-valued fields. */
    abstract fun toMap(): Map<String, Any>

    /** Absolute terminal coordinates. */
    data class Absolute(
        val row: Int = 0,
        val col: Int = 0,
    ) : Anchor() {
        override fun toMap(): Map<String, Any> = buildMap {
            put("type", "absolute")
            if (row != 0) put("row", row)
            if (col != 0) put("col", col)
        }
    }

    /** Relative to a tmux pane. */
    data class Pane(
        val paneId: String,
        val row: Int = 0,
        val col: Int = 0,
    ) : Anchor() {
        override fun toMap(): Map<String, Any> = buildMap {
            put("type", "pane")
            if (paneId.isNotEmpty()) put("pane_id", paneId)
            if (row != 0) put("row", row)
            if (col != 0) put("col", col)
        }
    }

    /** Relative to a neovim window / buffer line. */
    data class NvimWin(
        val winId: Int,
        val bufLine: Int = 0,
        val col: Int = 0,
    ) : Anchor() {
        override fun toMap(): Map<String, Any> = buildMap {
            put("type", "nvim_win")
            if (winId != 0) put("win_id", winId)
            if (bufLine != 0) put("buf_line", bufLine)
            if (col != 0) put("col", col)
        }
    }

    companion object {
        /** Create an absolute anchor. */
        fun absolute(row: Int = 0, col: Int = 0): Absolute = Absolute(row, col)

        /** Create a pane-relative anchor. */
        fun pane(paneId: String, row: Int = 0, col: Int = 0): Pane = Pane(paneId, row, col)

        /** Create a neovim window anchor. */
        fun nvimWin(winId: Int, bufLine: Int = 0, col: Int = 0): NvimWin = NvimWin(winId, bufLine, col)
    }
}

/**
 * Describes a single active placement.
 */
data class PlacementInfo(
    val placementId: Long = 0,
    val clientId: String = "",
    val handle: Long = 0,
    val visible: Boolean = false,
    val row: Int = 0,
    val col: Int = 0,
)

/**
 * Daemon status information.
 */
data class StatusResult(
    val clients: Int = 0,
    val placements: Int = 0,
    val images: Int = 0,
    val cols: Int = 0,
    val rows: Int = 0,
)

/**
 * Options for connecting to the kgd daemon.
 */
data class Options(
    val socketPath: String = "",
    val sessionId: String = "",
    val clientType: String = "",
    val label: String = "",
    val autoLaunch: Boolean = true,
)

/**
 * Optional source-crop and z-index parameters for [KgdClient.place].
 */
data class PlaceOpts(
    val srcX: Int = 0,
    val srcY: Int = 0,
    val srcW: Int = 0,
    val srcH: Int = 0,
    val zIndex: Int = 0,
)
