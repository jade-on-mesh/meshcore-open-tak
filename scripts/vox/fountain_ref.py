# Reference for lib/vox/vox_fountain.dart (rateless repair packets): the
# same GF(256) maths and coefficient hash, with a check that any m repair
# packets (and a spare) bring back m lost packets. Run: python3 scripts/vox/fountain_ref.py

# Python check of vox_fountain.dart's algorithm (same maths).
import random
EXP=[0]*512; LOG=[0]*256; x=1
for i in range(255):
    EXP[i]=x; x<<=1
    if x&0x100: x^=0x11d
for i in range(255,512): EXP[i]=EXP[i-255]
for i in range(255): LOG[EXP[i]]=i
mul=lambda a,b:0 if a==0 or b==0 else EXP[LOG[a]+LOG[b]]
inv=lambda a:EXP[255-LOG[a]]
def coef(seed,i):
    x=(seed*0x1F1+i*0x3B+0x5A17)&0xFFFF
    for _ in range(4):
        x=(x*0x9E37+0x7F4B)&0xFFFF
        x^=x>>7
    c=(x>>3)&0xFF
    return 1+((x>>8)%255) if c==0 else c
def add(dst,c,src):
    for k,s in enumerate(src[:len(dst)]):
        dst[k]^=mul(c,s)
def enc(pk,seed):
    p=max(len(d) for d in pk); out=[0]*p
    for i,d in enumerate(pk): add(out,coef(seed,i),d)
    return [len(pk[-1])]+out
def rebuild(total,present,rep):
    miss=[i for i in range(total) if i not in present]; m=len(miss)
    rows=list(rep.items())
    if len(rows)<m: return None
    p=len(rows[0][1])-1; last=rows[0][1][0]
    A=[];R=[]
    for seed,v in rows:
        v=list(v[1:])
        for i,d in present.items(): add(v,coef(seed,i),d)
        R.append(v); A.append([coef(seed,i) for i in miss])
    n=len(rows)
    for c in range(m):
        piv=next((r for r in range(c,n) if A[r][c]),None)
        if piv is None: return None
        A[c],A[piv]=A[piv],A[c]; R[c],R[piv]=R[piv],R[c]
        iv=inv(A[c][c]); A[c]=[mul(v,iv) for v in A[c]]; R[c]=[mul(v,iv) for v in R[c]]
        for r in range(n):
            if r==c or not A[r][c]: continue
            f=A[r][c]; A[r]=[a^mul(f,b) for a,b in zip(A[r],A[c])]; R[r]=[a^mul(f,b) for a,b in zip(R[r],R[c])]
    out={}
    for j,i in enumerate(miss): out[i]=R[j][:last] if i==total-1 else R[j]
    return out
random.seed(1); fails=0; trials=300
for t in range(trials):
    total=random.randint(5,60)
    pk=[[random.randrange(256) for _ in range(20)] for _ in range(total-1)]+[[random.randrange(256) for _ in range(random.randint(1,20))]]
    m=random.randint(1,min(15,total))
    miss=set(random.sample(range(total),m))
    present={i:pk[i] for i in range(total) if i not in miss}
    seeds=random.sample(range(255),m)  # exactly m repairs
    rep={s:enc(pk,s) for s in seeds}
    got=rebuild(total,present,rep)
    if got is None or any(got[i]!=pk[i] for i in miss): fails+=1
print('exact-m failures',fails,'of',trials)
fails=0
for t in range(trials):
    total=random.randint(5,60)
    pk=[[random.randrange(256) for _ in range(20)] for _ in range(total)]
    m=random.randint(1,min(15,total)); miss=set(random.sample(range(total),m))
    present={i:pk[i] for i in range(total) if i not in miss}
    rep={s:enc(pk,s) for s in random.sample(range(255),m+1)}
    got=rebuild(total,present,rep)
    if got is None or any(got[i]!=pk[i] for i in miss): fails+=1
print('m+1 failures',fails,'of',trials)
