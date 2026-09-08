"""Configure release signing from runner environment, never from debug keys."""

MARKER = '// medibox-permanent-signing'


def configure_android_signing(text):
    debug = 'signingConfigs.getByName("debug")'
    if MARKER in text:
        if debug in text:
            raise ValueError('Debug release signing must not remain')
        return text
    assignment = 'signingConfig = ' + debug
    if text.count(assignment) != 1 or '    buildTypes {' not in text:
        raise ValueError('Unrecognized Android signing template')
    text = text.replace(assignment, 'signingConfig = signingConfigs.getByName("mediboxRelease")')
    config = '''    // medibox-permanent-signing
    signingConfigs {
        create("mediboxRelease") {
            storeFile = System.getenv("MEDIBOX_KEYSTORE_PATH")?.let { file(it) }
            storePassword = System.getenv("MEDIBOX_KEYSTORE_PASSWORD")
            keyAlias = "medibox-release"
            keyPassword = System.getenv("MEDIBOX_KEYSTORE_PASSWORD")
            storeType = "PKCS12"
        }
    }

'''
    text = text.replace('    buildTypes {', config + '    buildTypes {', 1)
    return text + '''

gradle.taskGraph.whenReady {
    if (allTasks.any { it.name.contains("Release", ignoreCase = true) }) {
        check(!System.getenv("MEDIBOX_KEYSTORE_PATH").isNullOrBlank()) {
            "MediBox release signing key is not configured."
        }
        check(!System.getenv("MEDIBOX_KEYSTORE_PASSWORD").isNullOrBlank()) {
            "MediBox release signing password is not configured."
        }
    }
}
'''
