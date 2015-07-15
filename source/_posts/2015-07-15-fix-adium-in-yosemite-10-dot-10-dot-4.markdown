---
layout: post
title: "Fix Adium in Yosemite 10.10.4"
date: 2015-07-15 09:50:29 -0600
comments: false
author: <a href="http://twitter.com/p5k6">Josh Stanfield</a>
categories: yosemite adium
---

I recently (finally) upgraded to Yosemite on my work laptop. One of the programs I use frequently - Adium - would not start up (froze immediately upon startup).

I found the issue - Bonjour announcement (enabled by default on Yosemite) [seems to interfere with Adium](https://trac.adium.im/ticket/16827). However - the fixes listed for this all applied to pre 10.10.4 Yosemite (i.e. when Yosemite was still using discoveryd).

I fixed up by editing my mDNSResponder plist file 

```
cp /System/Library/LaunchDaemons/com.apple.mDNSResponder.plist ~
sudo plutil -convert json /System/Library/LaunchDaemons/com.apple.mDNSResponder.plist
sudo vim /System/Library/LaunchDaemons/com.apple.mDNSResponder.plist
```

When you edit the plist file, add "-NoMulticastAdvertisements" to the ProgramArguments array, so it looks like `ProgramArguments":["\/usr\/sbin\/mDNSResponder","-NoMulticastAdvertisements"]`

Then - convert back to binary and restart mDNSResponder
```
sudo plutil -convert binary1 /System/Library/LaunchDaemons/com.apple.mDNSResponder.plist
sudo killall -HUP mDNSResponder
```

Restart Adium (you may need to do force quit/`kill -9`), and all should be good
