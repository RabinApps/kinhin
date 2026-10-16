package screenshots;

import android.app.Instrumentation;
import android.content.Intent;
import android.os.SystemClock;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import org.junit.ClassRule;
import org.junit.Test;
import org.junit.runner.RunWith;

import tools.fastlane.screengrab.Screengrab;
import tools.fastlane.screengrab.locale.LocaleTestRule;

// One test per screen you want in the store. Call Screengrab.screenshot() with a name that sorts in the order you want.
// LocaleTestRule switches the device locale for each locale in the Screengrabfile. See docs/mobile-screenshots.md.
@RunWith(AndroidJUnit4.class)
public class ScreenshotTest {
    @ClassRule
    public static final LocaleTestRule localeTestRule = new LocaleTestRule();

    @Test
    public void captureHome() {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        Intent launch = instrumentation.getTargetContext().getPackageManager()
                .getLaunchIntentForPackage(instrumentation.getTargetContext().getPackageName());
        if (launch == null) {
            throw new IllegalStateException("the app has no launcher activity to start for screenshots");
        }
        // Some apps ask for Bluetooth or location on first launch, and the system dialog covers the screen in the capture.
        // Granting a permission the app does not declare is ignored, so this is safe for every app.
        String packageName = instrumentation.getTargetContext().getPackageName();
        for (String permission : new String[] {
                "android.permission.BLUETOOTH_SCAN",
                "android.permission.BLUETOOTH_CONNECT",
                "android.permission.ACCESS_FINE_LOCATION"}) {
            instrumentation.getUiAutomation().grantRuntimePermission(packageName, permission);
        }
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        instrumentation.getTargetContext().startActivity(launch);
        instrumentation.waitForIdleSync();
        // Flutter lays out its view after the locale switch restarts the activity. A capture taken earlier is blank
        // (logcat: "FlutterRenderer: Width is zero"), so give the first frame time to draw.
        SystemClock.sleep(4000);
        Screengrab.screenshot("01-home");
    }
}
