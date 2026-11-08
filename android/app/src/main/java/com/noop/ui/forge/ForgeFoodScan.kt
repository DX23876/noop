package com.noop.ui.forge

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.noop.R
import com.noop.core.CoreFood
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Fork (DX23876), decision 2026-11-08: scanning a product on Android, as iOS `ForgeFoodScanView`. CameraX frames are
 * decoded on the phone by ZXing (Apache 2.0); Google ML Kit is not used because it reports usage to Google. The code
 * is looked up in the wearer's own foods and the downloaded packs, online only when the wearer allowed it, and a
 * product still unknown is entered from its nutrition label in a form the wearer checks.
 */
@Composable
internal fun ForgeFoodScanPage(onBack: () -> Unit, onFound: (CoreFood.Item) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val prefs = remember { FoodDataPrefs(context) }
    var granted by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it }
    var manual by remember { mutableStateOf("") }
    var looking by remember { mutableStateOf<String?>(null) }
    var label by remember { mutableStateOf<String?>(null) }
    var labelOpen by remember { mutableStateOf(false) }

    fun lookUp(code: String) {
        val digits = code.filter { it.isDigit() }
        if (digits.length < 6 || looking != null) return
        looking = digits
        scope.launch {
            val found = withContext(Dispatchers.IO) {
                CoreFood.barcode(digits) ?: if (prefs.mode == FoodDataPrefs.ONLINE ||
                    (prefs.mode == FoodDataPrefs.PACKS && prefs.unknownBarcodesOnline))
                    CoreFood.onlineBarcode(digits, Locale.getDefault().language) else null
            }
            looking = null
            if (found != null) onFound(found) else { label = digits; labelOpen = true }
        }
    }

    if (labelOpen) {
        ForgeFoodLabelPage(barcode = label, onBack = { labelOpen = false }, onSaved = onFound)
        return
    }
    SettingsColumn {
        PageTitle(stringResource(R.string.food_scan), onBack)
        if (granted) {
            BarcodeCamera(Modifier.fillMaxWidth().height(320.dp)) { code -> lookUp(code) }
        } else {
            Text(stringResource(R.string.food_camera_needed), style = Forge.type.body, color = Forge.sceneInk.secondary)
            TextButton(onClick = { ask.launch(Manifest.permission.CAMERA) }) { Text(stringResource(R.string.food_allow_camera)) }
        }
        looking?.let { Text(stringResource(R.string.food_looking_up, it), style = Forge.type.body, color = Forge.sceneInk.secondary) }
        Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            OutlinedTextField(manual, { manual = it }, singleLine = true, modifier = Modifier.weight(1f),
                              label = { Text(stringResource(R.string.food_barcode_number)) },
                              keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
            TextButton(enabled = manual.length >= 6, onClick = { lookUp(manual) }) { Text(stringResource(R.string.food_look_up)) }
        }
        TextButton(onClick = { label = null; labelOpen = true }) { Text(stringResource(R.string.food_label_without_barcode)) }
    }
}

/** CameraX preview with ZXing decoding EAN-13, EAN-8, UPC and Code 128 on the luminance plane. */
@Composable
private fun BarcodeCamera(modifier: Modifier, onCode: (String) -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    val executor = remember { Executors.newSingleThreadExecutor() }
    val reported = remember { AtomicBoolean(false) }
    val reader = remember {
        MultiFormatReader().apply {
            setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.EAN_13, BarcodeFormat.EAN_8,
                BarcodeFormat.UPC_A, BarcodeFormat.UPC_E, BarcodeFormat.CODE_128), DecodeHintType.TRY_HARDER to true))
        }
    }
    DisposableEffect(Unit) { onDispose { executor.shutdown() } }
    AndroidView(modifier = modifier, factory = { ctx ->
        val view = PreviewView(ctx)
        val future = ProcessCameraProvider.getInstance(ctx)
        future.addListener({
            val provider = future.get()
            val preview = Preview.Builder().build().also { it.setSurfaceProvider(view.surfaceProvider) }
            val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
            analysis.setAnalyzer(executor) { image ->
                try {
                    if (!reported.get()) {
                        val plane = image.planes[0]
                        val bytes = ByteArray(plane.buffer.remaining()).also { plane.buffer.get(it) }
                        val source = PlanarYUVLuminanceSource(bytes, plane.rowStride, image.height, 0, 0, image.width, image.height, false)
                        val result = runCatching { reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))) }.getOrNull()
                        if (result != null && reported.compareAndSet(false, true)) {
                            ContextCompat.getMainExecutor(context).execute { onCode(result.text) }
                        }
                        reader.reset()
                    }
                } finally {
                    image.close()
                }
            }
            runCatching {
                provider.unbindAll()
                provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
            }
        }, ContextCompat.getMainExecutor(ctx))
        view
    })
}

/**
 * A nutrition label typed in, saved as the wearer's own food with the scanned barcode. Reading the label from a
 * photo on the phone needs the Tesseract language data, which is not in this build yet.
 */
@Composable
private fun ForgeFoodLabelPage(barcode: String?, onBack: () -> Unit, onSaved: (CoreFood.Item) -> Unit) {
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf("") }
    var brand by remember { mutableStateOf("") }
    var serving by remember { mutableStateOf("") }
    val fields = listOf("energy_kcal" to R.string.food_label_energy, "fat_g" to R.string.food_label_fat,
                        "sat_fat_g" to R.string.food_label_sat_fat, "carbs_g" to R.string.food_label_carbs,
                        "sugar_g" to R.string.food_label_sugar, "fiber_g" to R.string.food_label_fibre,
                        "protein_g" to R.string.food_label_protein, "salt_g" to R.string.food_label_salt)
    val values = remember { mutableStateOf(mapOf<String, String>()) }
    fun num(s: String?) = s?.replace(',', '.')?.toDoubleOrNull()
    val complete = name.isNotBlank() && listOf("energy_kcal", "protein_g", "carbs_g", "fat_g").all { num(values.value[it]) != null }
    SettingsColumn {
        PageTitle(stringResource(R.string.food_label_title), onBack)
        Text(stringResource(R.string.food_label_note), style = Forge.type.footnote, color = Forge.sceneInk.secondary)
        ForgeCard(Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                OutlinedTextField(name, { name = it }, label = { Text(stringResource(R.string.food_label_name)) }, singleLine = true)
                OutlinedTextField(brand, { brand = it }, label = { Text(stringResource(R.string.food_label_brand)) }, singleLine = true)
                barcode?.let { Text(stringResource(R.string.food_barcode_is, it), style = Forge.type.footnote, color = Forge.colors.textSecondary) }
                fields.forEach { (key, label) ->
                    OutlinedTextField(values.value[key] ?: "", { values.value = values.value + (key to it) },
                                      label = { Text(stringResource(label)) }, singleLine = true,
                                      keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
                }
                OutlinedTextField(serving, { serving = it }, label = { Text(stringResource(R.string.food_label_portion)) }, singleLine = true,
                                  keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
            }
        }
        TextButton(enabled = complete, onClick = {
            val per100 = values.value.mapNotNull { (k, v) -> num(v)?.let { k to it } }.toMap().toMutableMap()
            per100["salt_g"]?.let { if ("sodium_mg" !in per100) per100["sodium_mg"] = it / 2.5 * 1_000 }
            val item = CoreFood.itemJson("own:new", "online", name.trim(), brand.ifBlank { null }, num(serving), null, per100, barcode)
            scope.launch {
                val saved = withContext(Dispatchers.IO) { CoreFood.saveOwn(item, "label") }
                if (saved != null) onSaved(saved)
            }
        }) { Text(stringResource(R.string.food_save_food)) }
    }
}
