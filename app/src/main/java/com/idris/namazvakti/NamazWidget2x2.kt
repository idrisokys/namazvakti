package com.idris.namazvakti

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.os.Bundle

/** 2x2 widget: büyük saat + altında sıradaki vakte kalan süre. Çizim ve güncelleme NamazWidget'ta yapılır. */
class NamazWidget2x2 : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        NamazWidget.refresh(context, goAsync())
    }

    override fun onAppWidgetOptionsChanged(
        context: Context, manager: AppWidgetManager, id: Int, newOptions: Bundle
    ) {
        NamazWidget.refresh(context, goAsync()) // boyut değişti: yazı boyutlarını yeniden hesapla
    }

    override fun onDisabled(context: Context) {
        NamazWidget.cancelIfUnused(context)
    }
}
