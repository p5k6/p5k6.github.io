---
layout: post
title: "Automating HiveServer/Hive Metastore restarts after lockup"
date: 2015-05-15 11:08:36 -0600
comments: false
author: <a href="http://twitter.com/p5k6">Josh Stanfield</a>
categories: [hive, cloudera, cdh]
---
<script type="text/javascript" src="/javascripts/find-command-toggle.js"></script>

### Intro

At LivingSocial, one of the key components we use in the Hadoop ecosystem is Hive. I've been working here and seen us migrate from 0.7 up to (currently) 0.13.
One of the problems I've encountered over the years has been HiveServer (1 or 2) or the Hive Metastore "locking up" - i.e. calls to the service just hang. 
Usually when this happens, someone from our warehouse team will go into the server and manually restart the init.d service (as we are not using Ambari or Cloudera Manager).
However, depending on response times - this can cause issues when we have long running ETL jobs overnight.

This post addresses a new method I've recently discovered for emulating hive service lockups. These will probably be old hat for many java devs, but were new to me.

### Background

Over the years we've tried various monitor scripts to attempt to check to see if Hive is no longer responding. Some of the methods we've used include:

* Check for excessive CPU usage (usually Hive pegging one or more cores at 100%), 
* Real time scan of the log looking for errors and restart if a particular error was encountered > 20 times in a 2 min period,
* A "simple query" executed every 30 min (`select * from table limit 5`) 
* An every \{\{ unit of time \}\} restart of the underlying service (usually once a day, but sometimes more frequent)

These all work to varying degrees, but we still encounter the occasional lockup that slips through the various checks.
It would be great to be able to detect these lockups as soon as they occur, and immediately restart. 

### What I found

Basically, I wanted to find a way to lock up hive in a controlled enviornment. 
Looking up "how to lock up a jvm" on google was...interesting, and not very fruitful. 
Eventually, a coworker mentioned - "why not just use Thread.sleep()?". Which made a lot of sense to me.

But - i needed a way of injecting Thread.sleep() into the running hive-metastore process. So - I looked into JDB.
At first - I tried attaching jdb to the running job. However, I quickly found out that doing so results in a read-only jdb connection. 

So - I decided to try to start up the Hive Metastore using the jdb directly (click below to show how I figured out exactly what command to run)

test

<button id="toggle">←</button>

<div id="find-command" style="display: none;"> 
 
 teswttest test

{% markdown %}

So - I ran my which commands on my hive-metastore server. 
First - I looked at `/etc/init.d/hive-metastore`, and found the startup command for hive-metastore (which is effectively `su -s /bin/bash hive -c "hive --service metastore"`).
From here - I looked at the hive command in vim (`vim $(which hive)`), which lead me to `/usr/lib/hive/bin/ext/metastore.sh`.
This file, it turns out, calls `hadoop jar org.apache.hadoop.hive.metastore.HiveMetaStore`, so I took a look at the `hadoop` command.
`vim $(which hadoop)` lead me to /usr/lib/hadoop/bin/hadoop. In here - I finally see the acutal java call. However, it used a mix of env variables

So - I decided to just print the call to stderr (in addition to calling the program as normal) rather than trace all the variables by hand.

```bash
export CLASSPATH=$CLASSPATH
>&2 echo "$CLASSPATH"
>&2 echo "\"$JAVA\" $JAVA_HEAP_MAX $HADOOP_OPTS $CLASS \"$@\""
exec "$JAVA" $JAVA_HEAP_MAX $HADOOP_OPTS $CLASS "$@"
;;
```

This enabled me to start up hive-metastore in jdb! my final call to start it up was

```bash
jdb -classpath $CLASSPATH -Xmx1000m -Djava.net.preferIPv4Stack=true -server -Dhadoop.log.dir=/u/hadoop/var/log/hadoop -Dhadoop.log.file=hadoop.log -Dhadoop.home.dir=/usr/lib/hadoop -Dhadoop.id.str=hdfs -Dhadoop.root.logger=INFO,console -Djava.library.path=/usr/lib/hadoop/lib/native -Dhadoop.policy.file=hadoop-policy.xml -Djava.net.preferIPv4Stack=true  -Dhadoop.security.logger=INFO,NullAppender org.apache.hadoop.util.RunJar "/usr/lib/hive/lib/hive-service-0.13.1-cdh5.3.0.jar"  "org.apache.hadoop.hive.metastore.HiveMetaStore"
```

{% endmarkdown %}

</div>

I ran the following in jdb to "lock up" the metastore

```bash
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

I've played around with [rbhive](https://github.com/forward3d/rbhive) and knew that "thrift_socket" was the lowest point in its stack for HS2, so why not start there?
Instead of looking at thrift_socket though, I figured - let's just try a simple network socket. 
My first thought was - let's just say "hi" over a socket connection to the running metastore instance (i.e. before suspending)

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
Great! Now we've got a socket that times out when I try to read back from the socket! I also tried shutting down the metastore and connecting to the port - ended up with `Errno::ECONNREFUSED: Connection refused - connect(2) for 192.168.50.2:9083`. 
So - now we've got some relatively simple logic to determine whether the metastore has locked up! 

### The rest of the way

Now - I've got my logic, so I wrote a simple ruby script which daemonizes the above logic, and is controlled via a sysV init script (our servers are running CentOS).
My script runs the above logic every 30 seconds, and - on timeout - attempts restart - first by shutting down via service, then via kill -15 <pid>, and finally via kill -9 (if needed). 

One issue I found right after deploy was that the monitor was continuously restarting the metastore (oops...).
Turns out that I needed to close the write after writing "hello" to the socket.
After adding that to the above script, the monitor ran successfully (and has been for the last 2+ days so far).

Hopefully this will help us avoid additional downtime with hive-metastore.
