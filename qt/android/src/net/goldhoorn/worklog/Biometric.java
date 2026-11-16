package net.goldhoorn.worklog;

import android.app.Activity;
import android.app.KeyguardManager;
import android.content.Context;
import android.hardware.biometrics.BiometricManager;
import android.hardware.biometrics.BiometricPrompt;
import android.os.Build;
import android.os.CancellationSignal;

// Fingerprint/face (or the screen lock as fallback) before the app reads the saved login. Called from
// Biometric (C++), which receives the answer through the native onResult().
// This is the platform BiometricPrompt, not androidx.biometric: the androidx one needs a FragmentActivity,
// and Qt's activity is a plain Activity.
public class Biometric {
    private static native void onResult(boolean ok, String error);

    private static int authenticators() {
        return BiometricManager.Authenticators.BIOMETRIC_WEAK | BiometricManager.Authenticators.DEVICE_CREDENTIAL;
    }

    // a fingerprint/face is enrolled, or (Android 10+) there is a screen lock to fall back to
    public static boolean isAvailable(Context ctx) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            BiometricManager bm = ctx.getSystemService(BiometricManager.class);
            return bm != null && bm.canAuthenticate(authenticators()) == BiometricManager.BIOMETRIC_SUCCESS;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            KeyguardManager km = ctx.getSystemService(KeyguardManager.class);
            return km != null && km.isDeviceSecure();
        }
        return false;   // Android 9: no screen-lock fallback in BiometricPrompt
    }

    public static void authenticate(Activity activity, String title, String subtitle) {
        activity.runOnUiThread(() -> {
            try {
                BiometricPrompt.Builder b = new BiometricPrompt.Builder(activity)
                        .setTitle(title)
                        .setSubtitle(subtitle);
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                    b.setAllowedAuthenticators(authenticators());
                else
                    b.setDeviceCredentialAllowed(true);
                b.build().authenticate(new CancellationSignal(), activity.getMainExecutor(),
                        new BiometricPrompt.AuthenticationCallback() {
                            @Override
                            public void onAuthenticationSucceeded(BiometricPrompt.AuthenticationResult result) {
                                onResult(true, "");
                            }

                            @Override
                            public void onAuthenticationError(int code, CharSequence msg) {
                                onResult(false, msg == null ? "Not unlocked" : msg.toString());
                            }
                            // onAuthenticationFailed (a finger not recognised) keeps the prompt open
                        });
            } catch (Exception e) {
                onResult(false, String.valueOf(e.getMessage()));
            }
        });
    }
}
