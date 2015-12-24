module Echo where

import POSIX

root env = class

   echo str = action
      env.stdout.write str

   result 
      action 
         env.stdin.installR echo

