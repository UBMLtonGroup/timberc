-- Possible call
-- ./PingTimeServers time.nist.gov time-a.nist.gov time.ien.it
-- NB: It is explicitly disallowed to ask a NIST time server for time 
-- more frequently than once every 4 seconds.


module PingTimeServers where

import POSIX
import Data.Functional.List

port = Port 13  -- standard port for time servers

client neterror report sock = class

    established = action
       sock.inFile.installR report

    close = request result ()

    result Connection {..}
 

root env = class

    args = [1..size env.argv-1] 
    print i mess = env.stdout.write (env.argv!i ++ ": "++ mess ++ "\n")

    outstanding := args

    report i mess = action
       outstanding := delete i outstanding
       print i mess
       if (null outstanding) then env.exit 0
    
    result action
       forall i <- args do
          env.inet.tcp.connect (Host (env.argv!i)) port (client (report i) (report i))
       after (sec 2) action
          forall i <- outstanding do 
             print i "no response"
          env.exit 0
