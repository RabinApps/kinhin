/**
 * Sample React Native App
 * https://github.com/facebook/react-native
 *
 * @format
 */

import {
  I18nManager,
  Platform,
  Settings,
  StatusBar,
  StyleSheet,
  Text,
  useColorScheme,
  View,
} from 'react-native';
import {
  SafeAreaProvider,
  useSafeAreaInsets,
} from 'react-native-safe-area-context';

function App() {
  const isDarkMode = useColorScheme() === 'dark';

  return (
    <SafeAreaProvider>
      <StatusBar barStyle={isDarkMode ? 'light-content' : 'dark-content'} />
      <AppContent />
    </SafeAreaProvider>
  );
}

// The app's language. iOS reports it through SettingsManager, which follows -AppleLanguages (the screenshot tests set it);
// Intl and I18nManager on iOS can still report the process locale. Android's I18nManager follows the app locale.
function deviceLanguage(): string {
  if (Platform.OS === 'ios') {
    const languages = Settings.get('AppleLanguages') as string[] | undefined;
    const launched = Settings.get('KinhinLanguage') as string | undefined;
    return launched || languages?.[0] || '';
  }
  return I18nManager.getConstants().localeIdentifier ?? '';
}

function AppContent() {
  const safeAreaInsets = useSafeAreaInsets();

  // A greeting in the device language (English or French), so a French screenshot shows French text.
  const french = deviceLanguage().startsWith('fr');

  return (
    <View style={[styles.container, { paddingTop: safeAreaInsets.top }]}>
      <Text style={styles.greeting}>
        {french ? 'Bonjour de kinhin' : 'Hello from kinhin'}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  greeting: {
    fontSize: 24,
  },
});

export default App;
