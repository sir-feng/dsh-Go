package io.github.ccch1mneyyy.dsh_app.files

import android.content.Context
import java.io.File

/**
 * Where a path of the local environment lives on Android. The Linux runtime is
 * gone in this build, so only app-private files and the public download folder
 * resolve; everything else stays unresolved.
 */
object GuestFiles {
    fun rootfs(context: Context): File = File(context.filesDir, "runtime/rootfs")

    /** Host file for [path]; null unless it is a readable regular file. */
    fun resolve(context: Context, path: String): File? {
        if (!path.startsWith("/")) return null
        val base = path.removePrefix("/")
        val file = when {
            path.startsWith("/data/user/") || path.startsWith("/data/data/") -> File(context.filesDir, base.substringAfterLast("/"))
            path.startsWith("/sdcard/") || path.startsWith("/storage/emulated/0/") ->
                File(android.os.Environment.getExternalStoragePublicDirectory(null), path.substringAfter("0/"))
            else -> return null
        }
        return file.takeIf { it.isFile && it.canRead() }
    }
}
