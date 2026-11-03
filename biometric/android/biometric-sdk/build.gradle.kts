import java.util.Properties
import java.math.BigInteger

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.kenshikilabs.biometric"
    compileSdk = 36
    defaultConfig { minSdk = 26 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
kotlin { jvmToolchain(17) }

dependencies {
    testImplementation(libs.junit)
}

// Classic preserves out-of-range integer literals as BigInteger; JsonSlurper narrows them.
// Project shared JSON cases into typed test resources without a runtime parser dependency.
val portraitVectorsFile = layout.projectDirectory.file("../../../contracts/portrait-selfie-v1.vectors.json")
val portraitVectorsOutput = layout.buildDirectory.dir("generated/portrait-vectors")
val generatePortraitVectors by tasks.registering {
    inputs.file(portraitVectorsFile)
    val embeddingFile = layout.projectDirectory.file("../../../contracts/embedding-math-v1.vectors.json")
    inputs.file(embeddingFile)
    outputs.dir(portraitVectorsOutput)
    doLast {
        val fixture = groovy.json.JsonSlurperClassic().parse(portraitVectorsFile.asFile) as Map<*, *>
        val properties = Properties()
        fun fields(prefix: String, value: Map<*, *>) {
            value.forEach { (key, item) ->
                val tagged = when (item) {
                    null -> "n:"
                    is String -> "s:$item"
                    is Boolean -> "b:$item"
                    is Int, is Long -> "i:$item"
                    is BigInteger -> "j:$item"
                    is Number -> "f:$item"
                    else -> "x:"
                }
                properties.setProperty("$prefix$key", tagged)
            }
        }
        val pixels = fixture["pixelBase"] as Map<*, *>
        fields("pixel.", pixels["descriptor"] as Map<*, *>)
        fields("binding.", fixture["bindingBase"] as Map<*, *>)
        properties.setProperty("payloadHex", pixels["payloadHex"] as String)
        val vectors = fixture["vectors"] as List<*>
        properties.setProperty("count", vectors.size.toString())
        vectors.forEachIndexed { index, raw ->
            val vector = raw as Map<*, *>
            val prefix = "vector.$index."
            for (name in listOf("id", "kind", "expect", "payloadHex")) {
                (vector[name] as? String)?.let { properties.setProperty(prefix + name, it) }
            }
            (vector["overrides"] as? Map<*, *>)?.let { fields(prefix + "override.", it) }
            val removed = vector["removeFields"] as? List<*> ?: emptyList<Any>()
            properties.setProperty(prefix + "removeFields", removed.joinToString(","))
        }
        fun flatten(prefix: String, value: Any?) {
            when (value) {
                is Map<*, *> -> value.forEach { (key, item) -> flatten("$prefix.$key", item) }
                is List<*> -> {
                    properties.setProperty("$prefix.count", value.size.toString())
                    value.forEachIndexed { index, item -> flatten("$prefix.$index", item) }
                }
                else -> properties.setProperty(prefix, value.toString())
            }
        }
        flatten("math", groovy.json.JsonSlurperClassic().parse(embeddingFile.asFile))
        val output = portraitVectorsOutput.get().file("portrait-vectors.properties").asFile
        output.parentFile.mkdirs()
        output.outputStream().use { properties.store(it, null) }
    }
}
android.sourceSets.getByName("test").resources.srcDir(portraitVectorsOutput)
tasks.withType<Test>().configureEach { dependsOn(generatePortraitVectors) }
tasks.matching { it.name.startsWith("process") && it.name.endsWith("UnitTestJavaRes") }
    .configureEach { dependsOn(generatePortraitVectors) }
