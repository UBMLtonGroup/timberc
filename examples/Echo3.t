module Echo3 where

import POSIX

root env = class

   current := "Hello!\n"

   save str = action
      current := str

   tick = action
      env.stdout.write current
      after (sec 1) tick

   result 
      action 
         env.stdin.installR save
         tick
