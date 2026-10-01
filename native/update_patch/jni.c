#include <jni.h>
#include "decoder.h"
typedef struct { JNIEnv *env; jobject thread; jmethodID interrupted; } cancel_context;
static int cancelled(void *raw) {
  cancel_context *context = raw;
  return (*context->env)->CallBooleanMethod(context->env, context->thread, context->interrupted);
}
JNIEXPORT void JNICALL Java_com_example_resonance_ResonancePatchDecoder_apply(
    JNIEnv *env, jobject instance, jstring source, jstring patch, jstring output, jlong expected) {
  (void)instance;
  const char *s = (*env)->GetStringUTFChars(env, source, NULL);
  const char *p = (*env)->GetStringUTFChars(env, patch, NULL);
  const char *o = (*env)->GetStringUTFChars(env, output, NULL);
  if (!s || !p || !o) goto release;
  jclass threads = (*env)->FindClass(env, "java/lang/Thread");
  jmethodID current = (*env)->GetStaticMethodID(env, threads, "currentThread", "()Ljava/lang/Thread;");
  cancel_context context = {env, (*env)->CallStaticObjectMethod(env, threads, current),
    (*env)->GetMethodID(env, threads, "isInterrupted", "()Z")};
  char error[192];
  if (resonance_decode(s, p, o, (uint64_t)expected, cancelled, &context, error, sizeof(error))) {
    (*env)->ThrowNew(env, (*env)->FindClass(env, "java/io/IOException"), error);
  }
release:
  if (s) (*env)->ReleaseStringUTFChars(env, source, s);
  if (p) (*env)->ReleaseStringUTFChars(env, patch, p);
  if (o) (*env)->ReleaseStringUTFChars(env, output, o);
}
