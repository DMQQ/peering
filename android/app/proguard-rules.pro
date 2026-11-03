# sshj picks its ciphers, key exchanges and key formats by name, and BouncyCastle is registered as a provider by name.
-keep class com.hierynomus.** { *; }
-keep class net.schmizz.** { *; }
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# sshj references logging, GSS and Android-absent JDK classes it never reaches on a phone.
-dontwarn org.slf4j.**
-dontwarn org.ietf.jgss.**
-dontwarn javax.security.auth.**
-dontwarn com.sun.jna.**
-dontwarn net.i2p.crypto.eddsa.**
-dontwarn com.jcraft.jzlib.**

# kotlinx.serialization looks up the generated serializer of a class by name.
-keepattributes *Annotation*, InnerClasses
-keepclassmembers class **$$serializer { *; }
-keepclassmembers @kotlinx.serialization.Serializable class ** {
    static **$* *;
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
