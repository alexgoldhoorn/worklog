package net.goldhoorn.worklog;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import java.nio.charset.StandardCharsets;
import java.security.KeyStore;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

// Small secrets (the login password): an AES-GCM key that never leaves the Android Keystore encrypts
// the value; only IV + ciphertext (Base64) go to SharedPreferences. Called from SecretStore (C++).
public class SecretStore {
    private static final String ALIAS = "worklog_secret_key";
    private static final String PREFS = "worklog_secrets";

    private static SecretKey key() throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
        ks.load(null);
        if (ks.containsAlias(ALIAS))
            return (SecretKey) ks.getKey(ALIAS, null);
        KeyGenerator gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        gen.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build());
        return gen.generateKey();
    }

    private static SharedPreferences prefs(Context ctx) {
        return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    // null when nothing is stored; throws when a value is stored but cannot be decrypted (the Keystore key
    // is gone or invalid): callers that can tell the two apart say "sign in again" instead of "no password"
    static String lookup(Context ctx, String name) throws Exception {
        String stored = prefs(ctx).getString(name, null);
        if (stored == null)
            return null;
        byte[] all = Base64.decode(stored, Base64.NO_WRAP);
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, all, 0, 12));
        return new String(c.doFinal(all, 12, all.length - 12), StandardCharsets.UTF_8);
    }

    // For the app (C++): "" when missing or undecryptable; the failure's class is logged, never the secret
    public static String get(Context ctx, String name) {
        try {
            String v = lookup(ctx, name);
            return v == null ? "" : v;
        } catch (Exception e) {
            android.util.Log.w("SecretStore", "cannot decrypt '" + name + "': " + e.getClass().getName());
            return "";
        }
    }

    private static boolean put(Context ctx, String name, String value) throws Exception {
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, key());
        byte[] iv = c.getIV();
        byte[] ct = c.doFinal(value.getBytes(StandardCharsets.UTF_8));
        byte[] all = new byte[iv.length + ct.length];
        System.arraycopy(iv, 0, all, 0, iv.length);
        System.arraycopy(ct, 0, all, iv.length, ct.length);
        return prefs(ctx).edit().putString(name, Base64.encodeToString(all, Base64.NO_WRAP)).commit();
    }

    // true when stored. A broken Keystore key (invalidated, or lost) is replaced once and the write retried
    public static boolean set(Context ctx, String name, String value) {
        for (int attempt = 0; attempt < 2; attempt++) {
            try {
                return put(ctx, name, value);
            } catch (Exception e) {
                android.util.Log.w("SecretStore", "cannot store '" + name + "': " + e.getClass().getName());
                if (attempt == 0) {
                    try {
                        KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
                        ks.load(null);
                        ks.deleteEntry(ALIAS);
                    } catch (Exception ignored) {
                        return false;
                    }
                }
            }
        }
        return false;
    }

    public static void remove(Context ctx, String name) {
        prefs(ctx).edit().remove(name).commit();
    }
}
