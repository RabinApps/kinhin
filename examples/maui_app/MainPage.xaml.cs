using System.Globalization;

namespace MauiApp;

public partial class MainPage : ContentPage
{
	int count = 0;

	public MainPage()
	{
		InitializeComponent();
		GreetingLabel.Text = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "fr"
			? "Bonjour de kinhin"
			: "Hello from kinhin";
	}

	private void OnCounterClicked(object? sender, EventArgs e)
	{
		count++;

		if (count == 1)
			CounterBtn.Text = $"Clicked {count} time";
		else
			CounterBtn.Text = $"Clicked {count} times";

		SemanticScreenReader.Announce(CounterBtn.Text);
	}
}
