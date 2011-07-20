import os
import re
import sys

def bibtex(f):
  return os.spawnlp(os.P_WAIT, 'bibtex', 'bibtex', f)

def latex(f):
  return os.spawnlp(os.P_WAIT, 'pdflatex', 'pdflatex', f)

def grep(fn, r):
  f = open(fn, 'r')
  r = re.compile(r)
  for l in f:
    if r.search(l):
      f.close()
      return True
  f.close()
  return False

def compile(f):
  for i in range(10):
    if latex(f) != 0:
      return
    if grep('{0}.log'.format(f), 'No file.*bbl'):
      if bibtex(f) != 0:
        return
    if not grep('{0}.log'.format(f), '[Rr]erun'):
      return
  print('I run pdflatex 10 times for {0}. Something is wrong.'.format(f))
  print('Please take a look at {0}.log and see why it says "rerun".'.format(f))

for f in sys.argv[1:]:
  if f[-4:] == '.tex':
    f = f[:-4]
  compile(f)
