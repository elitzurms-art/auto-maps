// wic_convert.cpp — המרת HEIC/HEIF (וכל פורמט WIC אחר) ל-PNG דרך
// Windows Imaging Component. בלי תלויות חיצוניות — windowscodecs מובנה.
// פענוח HEIC דורש את "HEIF Image Extensions" של מיקרוסופט (מותקן
// כברירת-מחדל ב-Windows 11 וברוב התקנות Windows 10); בהיעדרו יוחזר 3.
//
// מוחזר 0 בהצלחה; קוד שלב-הכשל אחרת (לשגיאה ברורה בצד ה-Dart).
#include <windows.h>
#include <wincodec.h>

extern "C" __declspec(dllexport)
int wic_convert_to_png(const char* srcUtf8, const char* dstUtf8) {
  // UTF-8 → UTF-16 — נתיבים בעברית חייבים את ה-API הרחב.
  wchar_t src[2048], dst[2048];
  if (!MultiByteToWideChar(CP_UTF8, 0, srcUtf8, -1, src, 2048)) return 1;
  if (!MultiByteToWideChar(CP_UTF8, 0, dstUtf8, -1, dst, 2048)) return 1;

  const HRESULT hrInit = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool needUninit = SUCCEEDED(hrInit);

  int rc = 2;
  IWICImagingFactory* fac = nullptr;
  IWICBitmapDecoder* dec = nullptr;
  IWICBitmapFrameDecode* frame = nullptr;
  IWICFormatConverter* conv = nullptr;
  IWICStream* stream = nullptr;
  IWICBitmapEncoder* enc = nullptr;
  IWICBitmapFrameEncode* fenc = nullptr;
  IPropertyBag2* props = nullptr;

  do {
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&fac))))
      break;
    rc = 3;  // אין מפענח לפורמט (HEIF Extensions לא מותקן?) / קובץ לא נפתח
    if (FAILED(fac->CreateDecoderFromFilename(
            src, nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &dec)))
      break;
    rc = 4;
    if (FAILED(dec->GetFrame(0, &frame))) break;
    rc = 5;
    if (FAILED(fac->CreateFormatConverter(&conv))) break;
    if (FAILED(conv->Initialize(frame, GUID_WICPixelFormat32bppBGRA,
                                WICBitmapDitherTypeNone, nullptr, 0.0,
                                WICBitmapPaletteTypeCustom)))
      break;
    rc = 6;
    if (FAILED(fac->CreateStream(&stream))) break;
    if (FAILED(stream->InitializeFromFilename(dst, GENERIC_WRITE))) break;
    if (FAILED(fac->CreateEncoder(GUID_ContainerFormatPng, nullptr, &enc)))
      break;
    if (FAILED(enc->Initialize(stream, WICBitmapEncoderNoCache))) break;
    if (FAILED(enc->CreateNewFrame(&fenc, &props))) break;
    if (FAILED(fenc->Initialize(props))) break;
    rc = 7;
    if (FAILED(fenc->WriteSource(conv, nullptr))) break;
    if (FAILED(fenc->Commit())) break;
    if (FAILED(enc->Commit())) break;
    rc = 0;
  } while (false);

  if (props) props->Release();
  if (fenc) fenc->Release();
  if (enc) enc->Release();
  if (stream) stream->Release();
  if (conv) conv->Release();
  if (frame) frame->Release();
  if (dec) dec->Release();
  if (fac) fac->Release();
  if (needUninit) CoUninitialize();
  return rc;
}
