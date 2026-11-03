# Strict dependency verification

The reference application reuses the pinned SDK Gradle wrapper. Its verification metadata began with biometric/android/gradle/verification-metadata.xml and adds application packaging artifacts. Strict verification remains enabled.

These added SHA-256 values were independently fetched from Google Maven (`https://dl.google.com/dl/android/maven2/`) and matched the resolved metadata:

| Artifact | SHA-256 |
| --- | --- |
| com.android.application.gradle.plugin:8.13.2 POM | d4590cc0488efba782fb37d13e52812932f7efff10222ed2a96b7520bfdaa2af |
| aapt2:8.13.2-14304508 POM | 7e085634f503d42a4f3ea14488c25d4a573914db23c64a5a05a0c5c186c93112 |
| aapt2:8.13.2-14304508 osx JAR | 0d47f17c3924e5472b6125aa608d949dd7f46510889729671f31f2f4d801e8e7 |
| aapt2:8.13.2-14304508 linux JAR | 839609d6d776d6dd60a02aa577d97193ce3e650cf1deaabf062321e23bbd6bf6 |

Linux packaging is pinned for hosted CI; a direct download/hash is not a Linux build receipt. Changes to dependencies require reviewed metadata plus a fresh strict build; do not disable verification or add trusted-artifact wildcards.
