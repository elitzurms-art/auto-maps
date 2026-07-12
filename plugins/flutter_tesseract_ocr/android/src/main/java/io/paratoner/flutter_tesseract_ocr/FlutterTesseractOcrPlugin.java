package io.paratoner.flutter_tesseract_ocr;

import com.googlecode.tesseract.android.TessBaseAPI;

import android.os.Handler;
import android.os.Looper;
import androidx.annotation.NonNull;

import java.io.File;
import java.util.ArrayDeque;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/**
 * Vendored (auto_maps): החלפת המופע-היחיד + AsyncTask הטורי בבריכת
 * TessBaseAPI + thread-pool — קריאות-OCR מקביליות (אריחי-הרשת) מקבלות
 * מופעים נפרדים במקום להידרס/להיתקע בתור. גרסת-הבסיס: 0.4.31.
 */
public class FlutterTesseractOcrPlugin implements FlutterPlugin, MethodCallHandler {
  private static final int DEFAULT_PAGE_SEG_MODE = TessBaseAPI.PageSegMode.PSM_AUTO_OSD;
  private static final int POOL_SIZE = 3;

  // בריכת-מופעים: gated ב-synchronized; כל משימת-executor מחזיקה מופע אחד
  // לכל-היותר, ומספר-החוטים == גודל-הבריכה → לעולם לא נתקעים בלי מופע.
  private final ArrayDeque<TessBaseAPI> pool = new ArrayDeque<>();
  private int created = 0;
  private String poolLanguage = "";
  private String poolTessData = "";

  private final ExecutorService executor = Executors.newFixedThreadPool(POOL_SIZE);
  private final Handler mainHandler = new Handler(Looper.getMainLooper());

  private MethodChannel channel;

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
    BinaryMessenger messenger = flutterPluginBinding.getBinaryMessenger();
    channel = new MethodChannel(messenger, "flutter_tesseract_ocr");
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    if (channel != null) {
      channel.setMethodCallHandler(null);
      channel = null;
    }
    synchronized (pool) {
      for (TessBaseAPI api : pool) {
        api.recycle();
      }
      pool.clear();
      created = 0;
    }
    executor.shutdown();
  }

  /** שואל מופע מהבריכה (יוצר עד POOL_SIZE; שינוי-שפה מרוקן ובונה מחדש). */
  private TessBaseAPI borrow(String tessData, String language) throws InterruptedException {
    synchronized (pool) {
      if (!poolLanguage.equals(language) || !poolTessData.equals(tessData)) {
        for (TessBaseAPI api : pool) {
          api.recycle();
        }
        pool.clear();
        created = 0;
        poolLanguage = language;
        poolTessData = tessData;
      }
      while (true) {
        TessBaseAPI api = pool.pollFirst();
        if (api != null) return api;
        if (created < POOL_SIZE) {
          TessBaseAPI fresh = new TessBaseAPI();
          fresh.init(tessData, language);
          created++;
          return fresh;
        }
        pool.wait(); // מוחזר ב-give()
      }
    }
  }

  private void give(TessBaseAPI api) {
    synchronized (pool) {
      pool.addFirst(api);
      pool.notify();
    }
  }

  @Override
  public void onMethodCall(final MethodCall call, final Result result) {
    switch (call.method) {
      case "extractText":
      case "extractHocr":
        final String tessDataPath = call.argument("tessData");
        final String imagePath = call.argument("imagePath");
        final Map<String, String> args = call.argument("args");
        final boolean extractHocr = call.method.equals("extractHocr");
        String lang = "eng";
        if (call.argument("language") != null) {
          lang = call.argument("language");
        }
        final String language = lang;

        executor.execute(() -> {
          TessBaseAPI api = null;
          try {
            api = borrow(tessDataPath, language);
            int psm = DEFAULT_PAGE_SEG_MODE;
            if (args != null) {
              // המשתנים נקבעים פר-קריאה על המופע המושאל (נשמרים בו — אצלנו
              // אותם ערכים בכל קריאות-הרשת, אז אין זליגה בין קריאות).
              for (Map.Entry<String, String> entry : args.entrySet()) {
                if (!entry.getKey().equals("psm")) {
                  api.setVariable(entry.getKey(), entry.getValue());
                } else {
                  psm = Integer.parseInt(entry.getValue());
                }
              }
            }
            api.setPageSegMode(psm);
            api.setImage(new File(imagePath));
            final String text = extractHocr ? api.getHOCRText(0) : api.getUTF8Text();
            api.stop();
            mainHandler.post(() -> result.success(text));
          } catch (Exception e) {
            final String msg = e.getMessage() == null ? e.toString() : e.getMessage();
            mainHandler.post(() -> result.error("ocr_failed", msg, null));
          } finally {
            if (api != null) give(api);
          }
        });
        break;

      default:
        result.notImplemented();
    }
  }
}
