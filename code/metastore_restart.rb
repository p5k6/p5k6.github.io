Timeout::timeout(30) do
  socket = TCPSocket.new @hive_metastore_server, @hive_metastore_port
  begin 
    socket.write("hello")
    socket.close_write
    x = socket.read

    #not sure when this would happen....
    if x.nil? 
      @monitored_app_state = :unknown
      ### raise something eventually
    else
      conditional_log(:running, "hive metastore appears to be running ok")
      @monitored_app_state = :running
    end
  rescue Errno::ECONNRESET,Errno::ECONNREFUSED => e
    conditional_log(:dead, "exception #{e} found. This typically occurs when hive-metastore is not running. ")
    conditional_log(:dead, 'try running `sudo service hive-metastore status`')
    @monitored_app_state = :dead
  ensure
    socket.close
  end
rescue Timeout::Error
## restart hive-metastore!!
end
