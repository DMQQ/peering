# Apple Ads plan

Written 2026-10-01, the day the iPhone app was approved on the App Store. Starting credit: $65.
Everything here is a plan and a set of guesses, not measured data. Replace the guesses with real
numbers from App Store Connect and Apple Ads after about two weeks.

## What a paying user is worth

Yearly prices come from `PLANS-AND-FEATURES.md`. Apple keeps 15% under the Small Business Program
(30% if the app is not enrolled, so confirm that).

- Relay: $19.99/yr, about $17 net
- Relay Plus: $44.99/yr, about $38 net
- Pro: $79.99/yr, about $68 net

Most buyers take the cheapest tier. A blended first-year value is $20 to $25, and with renewals
lifetime value is about $30 to $40.

The free tier is generous (one relay hour a day, SSH, widgets, Wake on LAN), so the share of
installs that ever pay is low. Guess: 2% to 4%.

Break-even cost per install is lifetime value times paid conversion: $35 x 3% is about $1.05. At 2%
it is about $0.70, at 4% about $1.40. Remote desktop keywords in the US often cost $2 to $4 per
install, so most of this traffic loses money per user. Treat the $65 as a test that finds the real
cost per install, not as a channel.

Fixed costs are about $206/yr ($99 Apple Developer plus the Mikrus VPS), so 12 to 24 paying users
are needed just to stand still.

## Campaign settings (Apple Ads Advanced)

- Bid strategy: Manage Bids. Maximize Conversions is off, because it requires Search Match.
- Placement: Search Results.
- Daily budget: 5 EUR. There is no total budget field on the campaign page, so the End Date is the
  only cap. Apple bills the card once the credit is gone.
- End date: 11 days after the start, about 55 EUR. Check the credit balance and currency under
  Billing first. Apple can spend up to 2x the daily budget on one day.
- Campaign status was "App pending review". Review usually takes a few hours to a day, up to about
  two. Do not edit while it is in review, because edits can restart it.
- Match type: Exact on every keyword.
- Search Match: off on the four keyword ad groups. Optionally add a fifth ad group with Search Match
  on, no keywords and a max CPT of about $0.50, after 3 to 4 days if the exact keywords do not
  spend the daily budget.

## Countries

The default selection was 91 countries, which spreads 5 EUR a day to nothing. Use these seven:

```
United States, United Kingdom, Ireland, Canada, Australia, Netherlands, Sweden
```

The listing is English only. The relay is one box in Helsinki, but video is mostly direct, so the
distance only matters for relayed sessions. A single campaign cannot split the daily budget between
countries. After 3 to 4 days, open the Country or Region report and remove any country that spent
more than about 5 EUR with no installs. If the US gets almost no impressions, raise the max CPT on
ad group 3 to about $2.50 before dropping it.

Left out on purpose: India, Pakistan, Nigeria and similar (cheap taps, almost no paying users),
China mainland and Russia (payment and eligibility problems).

## Ad groups and keywords (Exact match)

Ad group 1, coding agents, max CPT $0.60:
```
claude code,claude code mobile,claude code iphone,claude code notifications,codex cli,ai coding agent,coding agent,ai agent terminal,approve from phone,notify when build finishes,long running build,terminal notifications
```

Ad group 2, SSH and terminal, max CPT $1.20:
```
ssh client,ssh iphone,ssh terminal,ssh app,terminal for iphone,iphone terminal,sftp client,sftp iphone,ssh port forwarding,ssh keys,termius,blink shell,shellfish,prompt ssh,moshi
```

Ad group 3, Mac remote control, max CPT $1.50:
```
control mac from iphone,remote desktop mac,mac remote control,mac remote desktop,mirror mac to iphone,access mac remotely,mac screen sharing,screen share mac iphone,wake on lan,wake on lan mac,jump desktop,screens,splashtop,parallels access,chrome remote desktop
```

Ad group 4, use-case phrases, max CPT $0.80:
```
check mac from phone,use mac from phone,work from phone,mac file transfer,mac from anywhere,remote mac access
```

Negative keywords, campaign level:
```
windows,android,teamviewer,anydesk,vnc server,free,crack,apk,linux,chromebook
```

Notes:
- Group 1 has the least competition and the best chance of a cheap, relevant tap. Expect low
  volume.
- Do not use competitor or Anthropic or OpenAI names in the ad text, only as keywords. Ads that
  imply an endorsement can be rejected.
- `screens` and `prompt ssh` are short and ambiguous. Pause either if it gets impressions and no
  taps after a couple of days.

## Suggested spend of the $65

- About $20 on ad group 1.
- About $25 on ad group 2 and the cheaper terms of ad group 3.
- About $20 held back, moved to the group with the best install rate after 3 to 4 days.

After 3 to 4 days, pause keywords with 50 or more impressions and no taps, and add negatives for
irrelevant queries.

## App Store Connect keyword field (free search traffic)

The old field repeated `mac`, `remote` and `screen`, which the name and subtitle already index. This
version drops them and adds the coding-agent angle. 98 of 100 characters:

```
iphone,ssh,terminal,sftp,agent,coding,ai,notifications,build,control,sharing,mirror,wake,lan,shell
```

`claude` and `codex` are left out on purpose (someone else's marks), as are `vnc` and `rdp`.
`clipboard` and `file transfer` were dropped to make room. Keyword changes only take effect with a
new version submission.

## Which plan will sell, and what the money looks like

Most likely to be bought: Relay, the cheapest tier, at $2.99/month or $19.99/year. Guess at the
mix of paying users: 70% Relay, 22% Relay Plus, 8% Pro. Blended net after Apple's 15%: about $26 per
paying user in the first year.

What the $65 test probably returns, with wide error bars:
- Cost per install around $2 to $2.50 in a US and UK mix, so about 26 to 32 installs.
- At 3% paid conversion, about 1 paying user, worth about $17 to $26 net.
- Result: roughly -$40 to -$50 before income tax. Break-even on the $65 needs about 3 to 4 paying
  users.

Per 1000 installs at 3% paid conversion (30 paying users):
- Revenue after Apple: about $770 in the first year.
- After income tax, assuming about 19% (confirm with an accountant): about $620.
- Less the $206/yr fixed costs: about $410.
- If those 1000 installs were bought at $2 each, the ads cost $2000, so paid installs at that price
  lose money. Organic installs (SEO pages, a Reddit or Hacker News post, the keyword field above)
  are where the profit comes from.

Apple collects and remits VAT and sales tax itself, so the 15% figure is already net of it. Income
tax depends on how the business is registered and is the main thing not modelled here.

## Check after about two weeks

1. Real cost per install per keyword and per country, from Apple Ads.
2. Real paid conversion per install, from App Store Connect subscriptions.
3. Keep spending past the $65 only if cost per install divided by paid conversion is below about
   $35. Otherwise each ad-sourced user loses money.

## Result of the first test (2026-10-01 to 2026-10-03)

Measured, not guessed. Exported from Apple Ads on 2026-10-03, currency EUR.

| Ad group | Spend | Impressions | Taps | Installs | Cost per install |
|---|---|---|---|---|---|
| Mac remote control | 13.52 | 705 | 17 | 2 | 6.76 |
| SSH & Terminal | 3.90 | 825 | 6 | 0 | n/a |
| Coding agents | 1.16 | 161 | 2 | 0 | n/a |
| General | 0.00 | 46 | 0 | 0 | n/a |
| Use-case phrases | 0.00 | 23 | 0 | 0 | n/a |
| Total | 18.58 | 1760 | 25 | 2 | 9.29 |

- Cost per install was about $10.80 against a break-even of about $1.05, roughly 10x over.
- Cost per tap (0.74) was normal. Tap to install was 8% on a sample of 25 taps.
- Even at a 30% tap to install rate the cost per install would be about 2.50 EUR, still more than
  double break-even.
- The coding-agent and use-case groups got almost no impressions, so the cheap niche has too little
  search volume to buy.
- No paying users, which is expected: at 3% paid conversion, 2 installs give about 0.06 buyers.

Decision: pause the campaign, set an end date (the export shows none), and leave the remaining credit
(about $40) unspent. Put the effort into organic traffic: the keyword field, the SEO pages, and a
Reddit or Hacker News post. The only paid follow-up worth trying is one Search Match ad group with a
max CPT of about $0.30 and a cap of about 5 EUR, dropped if it cannot beat about 1.50 EUR per install.
