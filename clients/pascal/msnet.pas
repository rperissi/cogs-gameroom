{ msnet.pas - the network layer of Milestones 2000 Network Version,
  as shipped. ORCA/Pascal 2.x, IIgs. This is a reference, not a unit:
  Milestones is one program, so these live inside it as the segment
  MSNET. Lift what you need. The pieces that are specific to the card
  game are marked; everything else is generic CoGS card + lobby code.

  Call order in a game:
    cogsfind                      find the card (any slot)
    netconnect                    link up, clock synced, POST /v1/join
    netstart                      poll /v1/wait until paired
    netsendline / netgetline      your moves out, the opponent's in
    netclose                      GET /v1/leave
    netscore                      POST /v1/score when the match ends

  Declarations the segment expects (from the program head): }

const
{ CoGS card: register offsets, frame opcodes, events (spec v0.7) }
       cogsidbyte=$A2;netsock=0;logsock=1;
       opjoin=$03;optime=$05;ophttp=$20;opjsonget=$32;
       everror=$93;evhttpdone=$95;evjson=$B2;evtime=$85;
       httpretain=$04;httpkeep=$08;
       msgame='milestones';msver='1';

type
     bptr=^byte;
     netbuf=array[0..1100] of byte;
     netbig=string[1000];

var
   netgame,netauto,netdead:boolean;
   netseat,netturn,neterr,rxop,rxlen,netstatus,netwaitms:integer;
   netticket,netcode:str200;netbody,neturl,netpost:netbig;netafter,netlastpoll:longint;
   netloghost:string[64];
   netseed,cogsbase:longint;
   nethost:string[64];
   netoppname:str12;
   oppn:str12;oppthe:string[20];oppH:Handle;
   netline:netbig;
   netrx,nettx:netbuf;
   me,foe:integer;


{ Also used from the rest of the program: humanname (string[12], the
  player's name from the options dialog), cnvis (integer to string),
  str12/str200 (string[12]/string[200]), gmymemoryID, and the toolbox
  calls tickcount, button, loword, randominteger, concat/copy/length.

  Game-specific pieces below: netlog (test harness state lines), netready
  (seat/seed into the game), netdecide/netsendmove (the "M action card"
  line protocol), netlost, netflip, donetgame (menu entry), readnetcfg
  (the MSNET settings file). Everything with a cogs* or nethttp/jsonget
  name is generic. }

{ The seeded generator the whole game draws from. In a network game both
  machines step the same Park-Miller stream from the lobby seed, so the
  deals match. Lives in the main segment in Milestones; shown here
  because lockstep depends on it. }

function myrand(r:integer):integer;
var hi,lo:longint;
begin
   if netgame
     then begin  { Park-Miller, same stream on both machines }
            hi:=netseed div 127773;lo:=netseed mod 127773;
            netseed:=16807*lo-2836*hi;
            if netseed<=0 then netseed:=netseed+2147483647;
            myrand:=loword(netseed mod r)+1;
          end
     else myrand:=(randominteger mod r) + 1;
end;

{$Segment 'MSNET'}
function cogsrd(off:integer):integer;
var p:bptr;l:longint;
begin
   l:=cogsbase+off;p:=bptr(l);
   cogsrd:=p^ & $FF;
end;

procedure cogswr(off:integer;v:integer);
var p:bptr;l:longint;
begin
   l:=cogsbase+off;p:=bptr(l);
   p^:=v;
end;

function cogsfind:boolean;
var s:integer;found:boolean;
begin
   found:=false;
   for s:=1 to 7 do
     if not found
       then begin
              cogsbase:=$E0C080+s*$10;
              if (cogsrd(5)=cogsidbyte) and (cogsrd(6)<>0)
                 and (cogsrd(1)<>$FF) then found:=true;
            end;
   cogsfind:=found;
end;

{ COGSGET: pop one byte, waiting up to five seconds; -1 on timeout }
function cogsget:integer;
var t0:longint;
begin
   t0:=tickcount;
   while ((cogsrd(1) & $80)=0) and (tickcount-t0<300) do begin end;
   if (cogsrd(1) & $80)<>0
     then cogsget:=cogsrd(0)
     else cogsget:=-1;
end;

procedure cogsput(b:integer);
begin
   repeat until (cogsrd(1) & $40)<>0;
   cogswr(0,b);
end;

{ COGSFRAME: send nettx[0..len-1] as a frame with opcode OP }
procedure cogsframe(op,len:integer);
var i:integer;
begin
   cogsput(op);cogsput(len & $FF);cogsput(len div 256);
   for i:=0 to len-1 do cogsput(nettx[i]);
end;

{ COGSRECV: read one frame into rxop/rxlen/netrx; false on timeout }
function cogsrecv:boolean;
var b,i,lo,hi:integer;ok:boolean;
begin
   rxop:=cogsget;ok:=(rxop>=0);
   lo:=0;hi:=0;
   if ok then begin lo:=cogsget;ok:=(lo>=0);end;
   if ok then begin hi:=cogsget;ok:=(hi>=0);end;
   rxlen:=lo+256*hi;
   i:=0;
   while ok and (i<rxlen) do
     begin
       b:=cogsget;ok:=(b>=0);
       if i<=1100 then netrx[i]:=b & $FF;
       i:=i+1;
     end;
   cogsrecv:=ok;
end;

{ NETHANDLE: an event we were not waiting for. Socket bytes go }
{   on netline; a close or error on our socket ends the game.   }
procedure nethandle;
begin
   { stray events while we wait for something else: only a card-level }
   { or our-socket error matters; DATA from a non-retained request is  }
   { ignored, and a closed keep-alive socket is normal.                }
   if (rxop=everror) and ((netrx[0]=netsock) or (netrx[0]=$FF)) then netdead:=true;
end;

{ COGSWAIT: drain frames until opcode WANT shows up (backstop cap) }
{ The tick limit is only a backstop: the card reports its own HTTP   }
{ timeouts as ERROR events, which land in nethandle. It has to outlast }
{ the longest lobby long poll (5 s) even when the GS clock runs far    }
{ ahead of wall time (MAME -nothrottle is ~28x), so 15000 ticks.       }
function cogswait(want:integer):boolean;
var ok:boolean;t0:longint;
begin
   ok:=false;t0:=tickcount;
   repeat
     if cogsrecv
       then begin
              if rxop=want then ok:=true else nethandle;
            end;
   until ok or netdead or (tickcount-t0>15000);
   cogswait:=ok;
end;

procedure netpoll;
begin
   while ((cogsrd(1) & $80)<>0) and not netdead do
     if cogsrecv then nethandle;
end;

{ SAMEWORD: string equality by length and characters. A quoted }
{   literal does not compare equal to a string variable here.   }
function sameword(var s:str200;w:str200):boolean;
var i:integer;ok:boolean;
begin
   ok:=(length(s)=length(w));
   if ok then for i:=1 to length(s) do if s[i]<>w[i] then ok:=false;
   sameword:=ok;
end;

{ NEXTTOK: pull the first space-separated word off S into T }
procedure nexttok(var s,t:str200);
var i,n:integer;
begin
   while (length(s)>0) and (s[1]=' ') do s:=copy(s,2,length(s)-1);
   n:=length(s);
   for i:=n downto 1 do if s[i]=' ' then n:=i-1;
   t:=copy(s,1,n);
   s:=copy(s,n+1,length(s)-n);
end;

function tolong(s:str200):longint;
var i:integer;v:longint;
begin
   v:=0;
   for i:=1 to length(s) do
     if (s[i]>='0') and (s[i]<='9') then v:=v*10+(ord(s[i])-48);
   tolong:=v;
end;

{ ============================================================= }
{  LOBBY CLIENT (cogs/spec/lobby-v0.1.md). Every call is one    }
{  HTTPS request through the card's HTTP command with the       }
{  response retained on the card, and the fields pulled out     }
{  with JSON_GET. The game's own lines ride inside:             }
{    M action card         move (relayed to the other seat)      }
{    K reply               1500 km choice: 1 go on, 0 stop       }
{    Q                     left the game                         }
{  L state lines go to the optional log sink (MSNET "log"),     }
{  never through the lobby.                                     }
{ ============================================================= }

{ NETHTTP: one request of NETURL with body NETPOST (globals, so no   }
{   1000-byte strings ride the stack). The reply is retained for     }
{   JSON_GET when RETAIN; netstatus gets the HTTP code.              }
function nethttp(sock:integer;retain:boolean;method:str200):boolean;
var i,n:integer;ok,fail:boolean;t0:longint;
begin
   netstatus:=0;ok:=false;fail:=netdead;
   if not fail
     then begin
            n:=0;
            nettx[n]:=sock;n:=n+1;
            if retain then nettx[n]:=httpretain+httpkeep else nettx[n]:=httpkeep;
            n:=n+1;
            nettx[n]:=length(method);n:=n+1;
            for i:=1 to length(method) do begin nettx[n]:=ord(method[i]);n:=n+1;end;
            nettx[n]:=length(neturl);n:=n+1;
            for i:=1 to length(neturl) do begin nettx[n]:=ord(neturl[i]);n:=n+1;end;
            nettx[n]:=0;nettx[n+1]:=0;n:=n+2;
            nettx[n]:=length(netpost) & $FF;nettx[n+1]:=length(netpost) div 256;n:=n+2;
            for i:=1 to length(netpost) do begin nettx[n]:=ord(netpost[i]);n:=n+1;end;
            cogsframe(ophttp,n);
            t0:=tickcount;
            repeat
              if cogsrecv
                then begin
                       if (rxop=evhttpdone) and (netrx[0]=sock)
                         then begin ok:=true;netstatus:=netrx[1]+256*netrx[2];end
                       else if (rxop=everror) and ((netrx[0]=sock) or (netrx[0]=$FF))
                         then fail:=true
                       else nethandle;
                     end;
            until ok or fail or netdead or (tickcount-t0>15000);
          end;
   nethttp:=ok and (netstatus=200);
end;

{ JSONGET: one field of the retained reply into netbody }
function jsonget(path:str200):boolean;
var i,n,vlen,got:integer;ok,fail:boolean;t0:longint;
begin
   netbody:='';got:=0;vlen:=0;ok:=false;fail:=false;
   nettx[0]:=netsock;nettx[1]:=length(path);
   for i:=1 to length(path) do nettx[1+i]:=ord(path[i]);
   cogsframe(opjsonget,2+length(path));
   t0:=tickcount;
   repeat
     if cogsrecv
       then begin
              if rxop=evjson
                then begin
                       if netrx[0]<>0
                         then fail:=true
                         else begin
                                vlen:=netrx[1]+256*netrx[2];
                                n:=rxlen-3;
                                for i:=0 to n-1 do
                                  if length(netbody)<1000
                                    then netbody:=concat(netbody,chr(netrx[3+i]));
                                got:=got+n;
                                if got>=vlen then ok:=true;
                              end;
                     end
                else nethandle;
            end;
   until ok or fail or (tickcount-t0>600);
   jsonget:=ok;
end;

{ BODYIS: the last JSON value equals W }
function bodyis(w:str200):boolean;
var s:str200;
begin
   s:=copy(netbody,1,200);
   bodyis:=sameword(s,w);
end;

{ NETOK: the retained reply says ok:1 }
function netok:boolean;
begin
   netok:=jsonget('ok') and bodyis('1');
end;

procedure lobbyurl(path:str200);
begin
   neturl:=concat('https://',nethost,path,'?t=',netticket);netpost:='';
end;

{ NETGETLINE: next line from the opponent. Polls the lobby when the  }
{   local buffer is empty, at most once per second unless NETWAITMS  }
{   asks the server to hold the poll (the unattended seat does).     }
function netgetline(var s:str200):boolean;
var i,j:integer;t:str200;
begin
   i:=0;
   for j:=length(netline) downto 1 do if netline[j]=chr(10) then i:=j;
   if (i=0) and not netdead and ((netwaitms>0) or (tickcount-netlastpoll>=60))
     then begin
            netlastpoll:=tickcount;
            lobbyurl('/v1/recv');
            neturl:=concat(neturl,'&a=',cnvis(loword(netafter)),'&w=',cnvis(netwaitms));
            if nethttp(netsock,true,'GET') and netok
              then begin
                     if jsonget('lines') then netline:=concat(netline,netbody);
                     if jsonget('next') then begin t:=copy(netbody,1,20);netafter:=tolong(t);end;
                     if jsonget('s') and bodyis('closed') then netdead:=true;
                   end
              else netdead:=true;
            for j:=length(netline) downto 1 do if netline[j]=chr(10) then i:=j;
          end;
   if i>0
     then begin
            s:=copy(netline,1,i-1);
            netline:=copy(netline,i+1,length(netline)-i);
            netgetline:=true;
          end
     else netgetline:=false;
end;

{ NETSENDLINE: one line to the opponent }
procedure netsendline(s:str200);
begin
   if not netdead
     then begin
            lobbyurl('/v1/send');
            netpost:=concat(s,chr(10));
            if not (nethttp(netsock,true,'POST') and netok) then netdead:=true;
          end;
end;

procedure netclose;
begin
   if (not netdead) and (length(netticket)>0)
     then begin
            lobbyurl('/v1/leave');
            if nethttp(netsock,false,'GET') then begin end;
          end;
   netdead:=true;netticket:='';
end;

{ NETREADY: pull seat, seed, opponent out of a ready reply }
procedure netready;
var t:str200;
begin
   if jsonget('seat') then begin t:=copy(netbody,1,20);netseat:=loword(tolong(t));end;
   if jsonget('seed') then begin t:=copy(netbody,1,20);netseed:=tolong(t);end;
   if netseed<=0 then netseed:=1;
   if netseat<>2 then netseat:=1;
   netoppname:='Opponent';
   if jsonget('opp') and (length(netbody)>0) then netoppname:=copy(netbody,1,12);
   oppn:=netoppname;oppthe:=netoppname;
end;

{ ADDNAME: append the player's name to neturl, URL-safe             }
procedure addname;
var i:integer;
begin
   for i:=1 to length(humanname) do
     if humanname[i]=' ' then neturl:=concat(neturl,'+')
     else if (humanname[i]>' ') and (humanname[i]<='~') and (humanname[i]<>'&')
            and (humanname[i]<>'#') and (humanname[i]<>'%') and (humanname[i]<>'+')
       then neturl:=concat(neturl,humanname[i]);
end;

{ NETSCORE: rally over; post my final points (best kept) and a win  }
{   (added up) to the lobby leaderboard. Unattended seats stay off it. }
procedure netscore(pts:integer;won:boolean);
begin
   if (not netauto) and (not netdead)
     then begin
            neturl:=concat('https://',nethost,'/v1/score?g=',msgame,'&x=pts&v=',
                           cnvis(pts),'&n=');
            addname;netpost:='';
            if nethttp(netsock,false,'POST') then begin end;
            if won
              then begin
                     neturl:=concat('https://',nethost,'/v1/score?g=',msgame,
                                    '&x=wins&m=add&v=1&n=');
                     addname;netpost:='';
                     if nethttp(netsock,false,'POST') then begin end;
                   end;
          end;
end;

{ NETCONNECT: card present, link up, clock set, joined the lobby.  }
{   True with netticket set; the match may already be ready        }
{   (netseat<>0) or still waiting (netseat=0).                     }
function netconnect:boolean;
var i:integer;ok:boolean;t0:longint;
begin
   netdead:=false;netline:='';netticket:='';netafter:=0;netseat:=0;
   netlastpoll:=0;
   ok:=cogsfind;
   if ok then netpoll;   { let stale events drain first }
   if ok and ((cogsrd(1) & $10)=0)
     then begin  { no link yet: join with the card's stored creds }
            nettx[0]:=0;nettx[1]:=0;
            cogsframe(opjoin,2);
            ok:=cogswait($83);
            if ok then ok:=(netrx[0]=0);
          end;
   if ok
     then begin  { verified TLS needs the card's clock; wait for NTP }
            t0:=tickcount;
            repeat
              cogsframe(optime,0);
              if cogswait(evtime)
                then ok:=(netrx[0]+netrx[1]+netrx[2]+netrx[3])<>0
                else ok:=false;
            until ok or netdead or (tickcount-t0>900);
          end;
   if ok
     then begin
            neturl:=concat('https://',nethost,'/v1/join?g=',msgame,'&v=',msver,'&n=');
            netpost:='';addname;
            if length(netcode)>0 then neturl:=concat(neturl,'&c=',netcode);
            ok:=nethttp(netsock,true,'POST') and netok;
            if ok then ok:=jsonget('t');
            if ok then begin netticket:=copy(netbody,1,32);ok:=(length(netticket)=16);end;
            if ok then begin if jsonget('s') and bodyis('ready') then netready;end;
          end;
   netconnect:=ok and not netdead;
end;

{ NETSTART: say hello, wait for the table to seat us }
function netstart:boolean;
var ok,gone:boolean;t0:longint;w:integer;
begin
   ok:=(netseat<>0);gone:=false;t0:=tickcount;
   if netauto then w:=5000 else w:=1000;
   while not (ok or gone or netdead) do
     begin
       lobbyurl('/v1/wait');
       neturl:=concat(neturl,'&w=',cnvis(w));
       if nethttp(netsock,true,'GET') and netok
         then begin
                if jsonget('s')
                  then begin
                         if bodyis('ready') then begin netready;ok:=true;end
                         else if bodyis('gone') then gone:=true;
                       end;
              end
         else netdead:=true;
       if (not netauto) and button(0) then gone:=true;   { a click cancels }
       if tickcount-t0>216000 then gone:=true;
     end;
   netstart:=ok and not netdead;
end;

{ NETLOG: one state line to the table, for the lockstep check }
procedure netlog;
var s:str200;i:integer;
begin
   s:=concat('L ',cnvis(netturn),' up',cnvis(upplayer),' ck',cnvis(ckpoint),
             ' left',cnvis(cardsleft),' d',cnvis(distance[human]),'/',
             cnvis(distance[GS]),' u',cnvis(upcard[human]),'/',
             cnvis(upcard[GS]),' h');
   for i:=1 to 7 do s:=concat(s,cnvis(Hands[human,i]),',');
   s:=concat(s,' g');
   for i:=1 to 7 do s:=concat(s,cnvis(Hands[GS,i]),',');
   if length(netloghost)>0
     then begin
            neturl:=concat('http://',netloghost,'/log?seat=',cnvis(netseat));
            netpost:=concat(s,chr(10));
            if nethttp(logsock,false,'POST') then begin end;
          end;
end;

{ NETLOST: the other seat is gone; tell the player, end the game }
procedure netlost(why:str200);
begin
   netclose;netgame:=false;
   initcursor;
   S1:=why;S2:='The network game is over.';S3:='';
   dooops;
   abortgame;
end;

{ NETFLIP: the seeded coin decides who starts; seat 1 wins on 1 }
function netflip:integer;
var m,o:integer;s:str200;
begin
   m:=myrand(2);
   if m=netseat then netflip:=human else netflip:=GS;
   if not netauto
     then begin
            if m=netseat
              then s:='10/You go first./^OK%'
              else s:=concat('10/',netoppname,' goes first./^OK%');
            stuffzeroes(s);
            o:=Alertwindow(1,nil,@s[1]);
            setport(gbordw);beginupdate(gbordw);
            drawbordwindow;endupdate(gbordw);
          end;
end;

{ NETDECIDE: the other seat's move, if it has arrived }
procedure netdecide;
var s,t:str200;a,c,w:integer;
begin
   if netgetline(s)
     then begin
            nexttok(s,t);
            if sameword(t,'M')
              then begin
                     nexttok(s,t);a:=loword(tolong(t));
                     nexttok(s,t);c:=loword(tolong(t));
                     w:=findcard(GS,c);
                     if (w=0) or (a<coup) or (a>discard)
                       then netlost('The two games disagree about the cards.')
                       else begin action:=a;card:=pullcard(w);end;
                   end
            else if sameword(t,'Q') then netlost(concat(netoppname,' left the game.'));
          end
   else if netdead then netlost('The connection dropped.');
end;

procedure netsendmove;
begin
   netsendline(concat('M ',cnvis(action),' ',cnvis(card)));
   if netdead then netlost('The connection dropped.');
end;

procedure dobegin; forward;

{ DONETGAME: Game menu, Network Game }
procedure donetgame;
begin
   if upplayer<>0
     then begin
            S1:='Finish or abort this game first.';S2:='';S3:='';dooops;
          end
     else begin
            waitcursor;
            if not netconnect
              then begin
                     netclose;
                     S1:='No CoGS card answered, or the lobby';
                     S2:=concat('at ',nethost,' did not.');S3:='';
                     initcursor;dooops;
                   end
            else if not netstart
              then begin
                     netclose;
                     S1:='Nobody came to play, or the lobby';
                     S2:='went away while we waited.';S3:='';
                     initcursor;dooops;
                   end
            else begin
                   netgame:=true;netturn:=0;
                   dobegin;
                   savable:=false;quitsaveline:='Quit';
                   setmitemname(@quitsaveline,kquititem);
                 end;
          end;
end;

{ READNETCFG: optional MSNET text file, one setting per line:     }
{   code XYZ   room code shared with a friend (public queue if none) }
{   auto       connect at launch; the computer plays this seat       }
{   lobby H    lobby host (default lobby.a2cogs.com)                 }
{   log H:P    plain-HTTP sink for L state lines (test harness only) }
procedure readnetcfg;
var GSn:GSOSInstring;oparms:openOSDCB;rparms:readwriteOSDCB;
    cparms:closeOSDCB;buf:packed array[0..255] of char;
    i,n,ln:integer;s,t,v:str200;
begin
   nethost:='lobby.a2cogs.com';netcode:='';netloghost:='';netauto:=false;ln:=0;
   netwaitms:=0;
   { the app's folder first, then the boot disk's System folder }
   GSn.thestring:='@:MSNET';GSn.size:=7;
   with oparms do begin pcount:=2;pathname:=@GSn;refnum:=0;end;
   openGS(oparms);
   if toolerror<>0
     then begin
            GSn.thestring:='1:MSNET';GSn.size:=7;
            with oparms do begin pcount:=2;pathname:=@GSn;refnum:=0;end;
            openGS(oparms);
          end;
   if toolerror<>0
     then begin
            GSn.thestring:='*:System:MSNET';GSn.size:=14;
            with oparms do begin pcount:=2;pathname:=@GSn;refnum:=0;end;
            openGS(oparms);
          end;
   neterr:=toolerror;
   if toolerror=0
     then begin
            with rparms do
              begin refnum:=oparms.refnum;databuffer:=@buf;
                    requestcount:=255;transfercount:=0;pcount:=4;end;
            readGS(rparms);
            n:=loword(rparms.transfercount);
            with cparms do begin pcount:=1;refnum:=oparms.refnum;end;
            CloseGS(cparms);
            s:='';ln:=0;
            for i:=0 to n do
              begin
                if (i=n) or (buf[i]=chr(13)) or (buf[i]=chr(10))
                  then begin
                         nexttok(s,t);
                         if length(t)>0
                           then begin
                                  ln:=ln+1;
                                  if sameword(t,'auto') then begin netauto:=true;netwaitms:=2000;end
                                  else begin
                                         nexttok(s,v);
                                         if sameword(t,'code') then netcode:=copy(v,1,16)
                                         else if sameword(t,'lobby') then nethost:=copy(v,1,64)
                                         else if sameword(t,'log') then netloghost:=copy(v,1,64);
                                       end;
                                end;
                         s:='';
                       end
                  else if length(s)<200 then s:=concat(s,buf[i]);
              end;
          end;
end;
