---
layout: post
title: "Automating HiveServer/Hive Metastore restarts after lockup"
date: 2015-05-15 11:08:36 -0600
comments: false
author: <a href="http://twitter.com/p5k6">Josh Stanfield</a>
categories: hive cloudera cdh
---

### Intro

At LivingSocial, one of the key components we use in the Hadoop ecosystem is Hive. I've been working here and seen us migrate from 0.7 up to (currently) 0.13.
One of the problems I've encountered over the years has been HiveServer(1/2)/Hive Metastore "locking up" - i.e. calls to the service just hang. 
Usually when this happens, someone from our warehouse team will go into the server and manually restart the init.d service (as we are not using Ambari or Cloudera Manager).
However, this can cause issues when we have long running ETL jobs overnight

TL;DR - I discovered that we could launch hive/hive-metastore in jdb, and once loaded, suspend threads, so the port would be open, but not respond. This enables me to develop services that scan for unresponsiveness and restart hive/hive-metastore as needed


This post addresses a new method I've recently discovered for emulating hive service lockups; These will probably be old hat for many java devs, but were new to me;

### Background

Over the years we've tried various monitor scripts to attempt to check to see if Hive is no longer responding. 
Some of the methods we've used are check for excessive CPU usage (usually Hive pegging one or more cores at 100%), 
real time scan of the log looking for errors and restart if a particular error was encountered > 20 times in a 2 min period,
a "simple query" executed every 30 min (`select * from table limit 5`) and
an every {{ unit of time }} restart of the underlying service.
These all work to varying degrees, but we still encounter the occasional lockup that slips through the various checks.
We've always needed a way to detect the problem at its core and take action, but that's - well, kinda hard. 
If you're an end user and submit a query - is hive locked up? is the metastore locked up? The user doesn't care. 


### What I found

Basically, I wanted to find a way to lock up hive in a controlled enviornment. 
Having encountered instances where hive locks up when a query is submitted, but the cpu is < 10%, the cpu solution isn't the greatest. 
The real time scan worked for one particular error (a weird ZK exception in HS2 portion of hive 0.10.0-cdh4.2.1).
The simple query works pretty well, but only runs every 30 min and it can be difficult to differentiate between issues with hive or the metastore.
So - I looked and looked. Looking up "how to lock up a jvm" on google was...interesting, and not very fruitful. 
Eventually, a coworker mentioned - "why not just use thread.sleep?". Which made a lot of sense to me.
But - i needed a way of injecting Thread.sleep into the running hive-metastore process. So - I looked into JDB.
At first - I tried attaching jdb to the running job. However, I quickly found out that doing so results in a read-only jdb connection. 
At least - for how I connected to the running process. 

So - I ran my which commands on my hive-metastore server. First - I looked at /etc/init.d/hive-metastore, and found the startup command for hive-metastore (which is effectively su -s /bin/bash hive -c "hive --service metastore")
from here - I looked at the hive command in vim `vim $(which hive)`, which lead me to /usr/lib/hive/bin/ext/metastore.sh (eventually!). 
This file, it turns out, calls `hadoop jar org.apache.hadoop.hive.metastore.HiveMetaStore`, so I took a look at the hadoop command :)
vim $(which hadoop), which lead me to /usr/lib/hadoop/bin/hadoop. In here - I finally see the acutal java call. 
So - I decided to just print the call to stderr (in addition to calling the program as normal) rather than trace all the variables by hand.

End of the /usr/lib/hadoop/bin/hadoop file after my mods in a dev box.
```shell
export CLASSPATH=$CLASSPATH
>&2 echo "$CLASSPATH"
>&2 echo "\"$JAVA\" $JAVA_HEAP_MAX $HADOOP_OPTS $CLASS \"$@\""
exec "$JAVA" $JAVA_HEAP_MAX $HADOOP_OPTS $CLASS "$@"
;;
```

This enabled me to start up hive-metastore in jdb! my final call to start it up was

```shell
jdb -classpath $CLASSPATH -Xmx1000m -Djava.net.preferIPv4Stack=true -server -Dhadoop.log.dir=/u/hadoop/var/log/hadoop -Dhadoop.log.file=hadoop.log -Dhadoop.home.dir=/usr/lib/hadoop -Dhadoop.id.str=hdfs -Dhadoop.root.logger=INFO,console -Djava.library.path=/usr/lib/hadoop/lib/native -Dhadoop.policy.file=hadoop-policy.xml -Djava.net.preferIPv4Stack=true  -Dhadoop.security.logger=INFO,NullAppender org.apache.hadoop.util.RunJar "/usr/lib/hive/lib/hive-service-0.13.1-cdh5.3.0.jar"  "org.apache.hadoop.hive.metastore.HiveMetaStore"
```

I ran the following in jdb to "lock up" the metastore

```shell
Initializing jdb ...
> run
run org.apache.hadoop.util.RunJar /usr/lib/hive/lib/hive-service-0.13.1-cdh5.3.0.jar org.apache.hadoop.hive.metastore.HiveMetaStore
Set uncaught java.lang.Throwable
Set deferred uncaught java.lang.Throwable
>
VM Started:
> threads
Group system:
(java.lang.ref.Reference$ReferenceHandler)0x160         Reference Handler                         cond. waiting
(java.lang.ref.Finalizer$FinalizerThread)0x15f          Finalizer                                 cond. waiting
(java.lang.Thread)0x15e                                 Signal Dispatcher                         running
(java.lang.Thread)0x45e                                 process reaper                            cond. waiting
Group main:
(java.lang.Thread)0x1                                   main                                      running
(org.apache.hadoop.hive.metastore.HiveMetaStore$3)0x552 Thread-4                                  cond. waiting
(com.google.common.base.internal.Finalizer)0x72c        com.google.common.base.internal.Finalizer cond. waiting
(java.lang.Thread)0x744                                 BoneCP-keep-alive-scheduler               cond. waiting
(java.lang.Thread)0x746                                 BoneCP-pool-watch-thread                  cond. waiting
(com.google.common.base.internal.Finalizer)0x84f        com.google.common.base.internal.Finalizer cond. waiting
(java.lang.Thread)0x850                                 BoneCP-keep-alive-scheduler               cond. waiting
(java.lang.Thread)0x851                                 BoneCP-pool-watch-thread                  cond. waiting
> suspend 0x1
>
```

By suspending the thread, I could now see how other apps would respond. I proceeded to issue a "desc table" command via beeline. It hung!
So - now I've got something which appears to emulate a "metastore lockup". 

So - what can I do with this info?

### How can I tell if the metastore locked up?

Well - I had a handful of thoughts on this matter, but I figured - what if we just went to the socket level. 
I've played around with [rbhive](https://github.com/forward3d/rbhive) and knew that "thrift_socket" was the lowest point in its stack for HS2, so why not start there?
Instead of looking at thrift_socket though, I figured - let's just try a simple network socket. 
My first thought was - let's just say "hi" over a socket connection to a running instance

```ruby
[44] pry(main)> socket = Socket.new(:INET, :STREAM)
=> #<Socket:fd 15>
[45] pry(main)> socket.connect(sockaddr)
=> 0
[46] pry(main)> socket.write("GET / HTTP/1.0\r\n\r\n")
=> 18
[47] pry(main)> socket.read
=> ""
```
hmmm - I've got an empty string back. Not nil. Interesting. What happens when I try to do this with the thread asleep

```ruby
[71] pry(main)> Timeout::timeout(15) {
[71] pry(main)*   socket = Socket.new(:INET, :STREAM)
[71] pry(main)*   socket.connect(sockaddr)
[71] pry(main)*
[71] pry(main)*   socket.write("hello")
[71] pry(main)*   socket.read
[71] pry(main)* }
Timeout::Error: execution expired
from (pry):84:in `read'
```
Great! Now we've got a socket that times out when I try to read back from the socket! I also tried shutting down and connecting - ended up with `Errno::ECONNREFUSED: Connection refused - connect(2) for 192.168.50.2:9083`. 
So - now we've got some relatively simple logic to determine whether the metastore has locked up! 

### The rest of the way

Now - I've got my logic, so I'm currently in the process of writing a simple ruby script which daemonizes the above logic, and is controlled via a sysV init script (our servers are running centos).
My script runs the above logic every 15 seconds, and - on timeout -attempts restart - first by shutting down via service, then via kill -15 <pid>, and finally via kill -9 (if needed). 

Hopefully this will help us avoid additional downtime with hive-metastore.
