package com.haishinkit.vqmetrix

import java.io.File

/** A completed capture archive and its local receipt directory. */
data class BatchArchive(val runId: String, val directory: File, val archive: File)
