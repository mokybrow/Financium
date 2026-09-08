Widget snapshot checks (macOS):

```sh
xcrun swiftc FinanciumWidgets/WidgetSnapshot.swift Tests/Widgets/SnapshotChecks.swift -o /tmp/financium-widget-checks
/tmp/financium-widget-checks
```

Device verification:
- Add small and medium summary, quick entry, and a selected budget.
- Add income, expenses, and monthly net on the Lock Screen; check circular, rectangular and inline layouts.
- Check light/dark/tinted appearances, larger text, VoiceOver and privacy redaction.
- Check zero amounts, negative net, overspending, long budget names and large amounts.
- Select a past period in the app: widgets must still display this month; tapping a monthly widget opens this month.
- Test missing data and a snapshot from a previous month: no demo figures or old monthly totals should appear.
- WidgetKit controls refresh scheduling; new data arrives from the app, not directly from CloudKit in the extension.
