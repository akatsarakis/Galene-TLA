------------------------------- MODULE Galene -------------------------------
\* Galene: is a linearizable protocol used in ccKVS of Scale-out ccNUMA [Eurosys'18]
\* This spec actually includes two variants of Galene one that does not accepts 
\* concurrent writes (SWMR) but allows for read-modify-writes and 
\* the one actually used in the paper that permits concurrent writes (MWMR).
\* Setting the constant enableMWMR TRUE or FALSE verifies either variant accordingly.

EXTENDS     Integers,
            FiniteSets

CONSTANTS   G_NODES,
            G_MAX_VERSION,
            enableMWMR
            
VARIABLES   msgs,
            nodeTS,
            nodeState, 
            nodeRcvedAcks
            
ASSUME enableMWMR \in {TRUE, FALSE}

\* all Galene (+ environment) variables
gvars == << msgs, nodeTS, nodeState, nodeRcvedAcks>>
-------------------------------------------------------------------------------------

\* A buffer maintaining all network messages. Messages are only appended to this variable (not 
\* removed once delivered) intentionally to check protocols tolerance in dublicates and reorderings 
send(m) == msgs' = msgs \union {m}

\* Check if all acknowledgments for a write have been received                                                  
receivedAllAcks(n) == (G_NODES \ {n}) \subseteq nodeRcvedAcks[n]
        
equalTS(v1,tb1,v2,tb2)   == \* Timestamp equality
    /\ v1 = v2
    /\ tb1 = tb2

greaterTS(v1,tb1,v2,tb2) == \* Timestamp comparison
    \/ v1 > v2
    \/ /\   v1 = v2
       /\  tb1 > tb2
-------------------------------------------------------------------------------------

GMessage ==  \* Messages exchanged by Galene
    [type: {"INV", "ACK"}, sender    : G_NODES,
                           version   : 0..G_MAX_VERSION,  
                           tieBreaker: G_NODES] 
        \union
    \* We do not send the Value w/ UPDs (TS suffices to check consistency)
    [type: {"UPD"},        version   : 0..G_MAX_VERSION, 
                           tieBreaker: G_NODES] 

GTypeOK ==  \* The type correctness invariant
    /\ msgs                \subseteq GMessage
    /\ \A n \in G_NODES: nodeRcvedAcks[n] \subseteq (G_NODES \ {n})
    /\ nodeTS              \in [G_NODES -> [version   : 0..G_MAX_VERSION,
                                            tieBreaker: G_NODES         ]]
    /\ nodeState           \in [G_NODES -> {"valid", "invalid", "write"}] 
            
                                              

\* The consistent invariant: all alive nodes in valid state should have the same TS (value)
GConsistent == 
    \A k,s \in G_NODES: \/ nodeState[k] # "valid"
                        \/ nodeState[s] # "valid" 
                        \/ nodeTS[s]    = nodeTS[k]
                                              
GSWMR ==  \* veryfying exactly one write is committed per version
    \/ enableMWMR
    \/ \A m,l \in msgs : \/ m.type    # "UPD"
                         \/ l.type    # "UPD"
                         \/ m.version # l.version
                         \/ m.tieBreaker = l.tieBreaker


GInit == \* The initial predicate
    /\ msgs                = {}
    /\ nodeRcvedAcks       = [n \in G_NODES |-> {}]
    /\ nodeState           = [n \in G_NODES |-> "valid"]
    /\ nodeTS              = [n \in G_NODES |-> [version    |-> 0, 
                                                 tieBreaker |-> 
                                                   CHOOSE k \in G_NODES: 
                                                   \A m \in G_NODES: k <= m]]

-------------------------------------------------------------------------------------

g_actions_for_upd(n, newVersion, newTieBreaker, newState, newAcks) == 
    /\ nodeRcvedAcks'    = [nodeRcvedAcks   EXCEPT ![n] = newAcks]
    /\ nodeState'        = [nodeState       EXCEPT ![n] = newState]
    /\ nodeTS'           = [nodeTS          EXCEPT ![n].version    = newVersion, 
                                                   ![n].tieBreaker = newTieBreaker]
    /\ send([type        |-> "INV",
             sender      |-> n,
             version     |-> newVersion, 
             tieBreaker  |-> newTieBreaker])              
-------------------------------------------------------------------------------------

GRead(n) ==  \* Execute a read
    /\ nodeState[n] = "valid"
    /\ UNCHANGED gvars
              
GWrite(n) == \* Execute a write
    /\  nodeState[n] = "valid"
    /\  nodeTS[n].version < G_MAX_VERSION \* to configurably terminate the model checking 
    /\  g_actions_for_upd(n, nodeTS[n].version + 1, n, "write", {})


GRcvAck(n) ==   \* Process received Ack
    \E m \in msgs: 
        /\ m.type       = "ACK"
        /\ nodeState[n] = "write"
        /\ m.sender     # n
        /\ m.sender     \notin nodeRcvedAcks[n]
        /\ equalTS(m.version, m.tieBreaker,
                   nodeTS[n].version, 
                   nodeTS[n].tieBreaker)
        /\ nodeRcvedAcks' = [nodeRcvedAcks EXCEPT ![n] = 
                                   nodeRcvedAcks[n] \union {m.sender}]
        /\ UNCHANGED <<msgs, nodeTS, nodeState>>


GSendUpds(n) == \* Send validations once acknowledments from all nodes are received 
    /\ receivedAllAcks(n)
    /\ nodeState[n] = "write"
    /\ send([type        |-> "UPD", 
             version     |-> nodeTS[n].version, 
             tieBreaker  |-> nodeTS[n].tieBreaker])
    /\ nodeState'   = [nodeState EXCEPT![n] = "valid"]
    /\ UNCHANGED <<nodeTS, nodeRcvedAcks>>
 
GCoordinatorActions(n) ==   \* Coordinator actions for reads or writes
    \/ GRead(n)          
    \/ GWrite(n)         
    \/ GRcvAck(n)
    \/ GSendUpds(n) 
-------------------------------------------------------------------------------------               
    
ACK_already_send(n, m) == \* only to keep the state space small (we do not re-send ACKs previously sent)
    \E k \in msgs:
        /\ k.type       = "ACK"
        /\ k.sender     = n 
        /\ k.version    = m.version
        /\ k.tieBreaker = m.tieBreaker


GRcvInvSWMR(n, m) ==  \* apply and respond to invalidation iff greater ts 
        /\ greaterTS(m.version, m.tieBreaker,
                       nodeTS[n].version, 
                       nodeTS[n].tieBreaker)
        /\ send([type       |-> "ACK",
                 sender     |-> n,   
                 version    |-> m.version,
                 tieBreaker |-> m.tieBreaker])
        /\ nodeState' = [nodeState EXCEPT ![n] = "invalid"]
        /\ nodeTS'    = [nodeTS    EXCEPT ![n].version    = m.version,
                                                  ![n].tieBreaker = m.tieBreaker]
        /\ UNCHANGED <<nodeRcvedAcks>>
 
GRcvInvMWMR(n, m) ==  \* (if MWMR is enabled) send an ACK even if not greater ts 
        /\ enableMWMR = TRUE
        /\ ~greaterTS(m.version, m.tieBreaker,
                       nodeTS[n].version, 
                       nodeTS[n].tieBreaker)
        /\ ~ACK_already_send(n, m)
        /\ send([type       |-> "ACK",
                 sender     |-> n,   
                 version    |-> m.version,
                 tieBreaker |-> m.tieBreaker])
        /\ UNCHANGED <<nodeRcvedAcks, nodeTS, nodeState>>
     
GRcvInv(n, m) ==
        /\ m.type     = "INV"
        /\ m.sender   # n
        /\ \/ GRcvInvSWMR(n, m)
           \/ GRcvInvMWMR(n, m)

            
GRcvUpd(n, m) ==   \* Process received validation iff same ts
        /\ m.type       = "UPD"
        /\ nodeState[n] # "valid"
        /\ equalTS(m.version, m.tieBreaker,
                   nodeTS[n].version, 
                   nodeTS[n].tieBreaker)
        /\ nodeState' = [nodeState EXCEPT ![n] = "valid"]
        /\ UNCHANGED <<msgs, nodeTS, nodeRcvedAcks>>
   
GFollowerActions(n) ==  \* Follower actions for writes 
    \E m \in msgs: 
        \/ GRcvInv(n, m)
        \/ GRcvUpd(n, m) 
------------------------------------------------------------------------------------- 

GNext == 
    \E n \in G_NODES:       
            \/ GFollowerActions(n)
            \/ GCoordinatorActions(n)


G_Spec == GInit /\ [][GNext]_gvars


THEOREM G_Spec =>([]GTypeOK) /\ ([]GConsistent) /\ ([]GSWMR)
=============================================================================