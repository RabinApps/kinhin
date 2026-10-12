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
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        instrumentation.getTargetContext().startActivity(launch);
        instrumentation.waitForIdleSync();
        SystemClock.sleep(1000); // let the first frame draw before the capture
        Screengrab.screenshot("01-home");
    }
}
