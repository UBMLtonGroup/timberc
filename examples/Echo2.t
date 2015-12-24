module Echo2 where

import POSIX

root env = class

   count := 1

   prompt = do
      env.stdout.write (show count++"> ")
      count := count+1

   echo str = action
      env.stdout.write str
      prompt

   result 
      action 
         env.stdin.installR echo
         env.stdout.write "Welcome to Echo2!\n"
         prompt

