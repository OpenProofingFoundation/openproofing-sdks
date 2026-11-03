package com.kenshiki.reference

import com.kenshiki.presentation.design.KenshikiCopy
import com.kenshiki.reference.design.resourceId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class DesignResourcesTest {
    @Test fun catalogResourceIdsMatchTheirDeclaredNames() {
        val resolved = KenshikiCopy.entries.map { message ->
            val expected = R.string::class.java.getField(message.resourceName).getInt(null)
            val actual = message.resourceId()
            assertEquals(message.key, expected, actual)
            assertNotEquals(message.key, 0, actual)
            actual
        }
        assertEquals(KenshikiCopy.entries.size, resolved.toSet().size)
    }
}
