//
//  Transactions.swift
//  Parallel-iOS
//
//  Created by Robert Widmann on 9/25/14.
//  Copyright (c) 2014 TypeLift. All rights reserved.
//

import Basis

/// Software Transaction Memory is a terribly tricky thing to do in a profoundly impure language,
/// but that never stopped me before...
///
/// This implementation of an STM transaction manager comes straight from
///
/// David Sabel, "A Haskell-Implementation of STM Haskell with Early Conflict Detection"
/// http://ceur-ws.org/Vol-1129/paper48.pdf
/// 
/// whose formalizations in Haskell were absolutely invaluable.  To that end, the implementation
/// matches the one described in the paper as much as possible with the exception of the existential
/// types hiding a lot of the plumbing.  While we don't get the proper benefits the paper outlines,
/// there is a bit of efficiency gained by de-duplicating all of the extra TVars it had lying around.
private let globalCounter : MVar<TVarId> = !newMVar(0)

internal func nextCounter() -> IO<TVarId> {
	return do_ { () -> TVarId in
		let i : Int = !takeMVar(globalCounter)
		putMVar(globalCounter)(i + 1)
		return i
	}
}

struct TransactionLog<A> {
	let readTVars : Set<TVar<A>>
	let tripleStack : [(Set<TVar<A>>, Set<TVar<A>>, Set<TVar<A>>)]
	let lockingSet : Set<TVar<A>>

	init(_ readTVars :Set<TVar<A>>, _ tripleStack : [(Set<TVar<A>>, Set<TVar<A>>, Set<TVar<A>>)], _ lockingSet : Set<TVar<A>>) {
		self.readTVars = readTVars
		self.tripleStack = tripleStack
		self.lockingSet = lockingSet
	}
}

func emptyTLOG<A>() -> IO<IORef<TransactionLog<A>>> {
	return do_ { () -> IORef<TransactionLog<A>> in
		let p : IORef<TransactionLog<A>> = !newIORef(TransactionLog<A>(empty(), [(empty(), empty(), empty())], empty()))
		return p
	}
}

func newTVarWithLog<A>(log : IORef<TransactionLog<A>>)(tvar : TVar<A>) -> IO<TVar<A>> {
	return do_ { () -> TVar<A> in
		let lg = !readIORef(log)

		switch destruct(lg.tripleStack) {
			case .Empty:
				assert(false, "")
			case .Destructure(let (la, ln, lw), let xs):

				let lg2 = TransactionLog(lg.readTVars, [(insert(tvar)(la), insert(tvar)(ln), lw)], lg.lockingSet)
				!writeIORef(log)(v: lg2)
				return tvar
		}

	}
}

func readTVarWithLog<A>(log : IORef<TransactionLog<A>>)(v : TVar<A>) -> IO<A> {
	return do_ { () -> IO<A> in
		let res : Either<MVar<()>, A> = !tryReadTvarWithLog(log)(ptvar: v)
		switch res.destruct() {
			case .Right(let r):
				return IO.pure(r.unBox())
			case .Left(let blockvar):
				return do_ {
					!takeMVar(blockvar.unBox())
					return readTVarWithLog(log)(v: v)
				}
		}
	}
}


func tryReadTvarWithLog<A>(log : IORef<TransactionLog<A>>)(ptvar : TVar<A>) -> IO<Either<MVar<()>, A>> {
	return do_ {
		let _tva : ITVar<A> = !takeMVar(ptvar.tvar)

		let lg = !readIORef(log)
		switch destruct(lg.tripleStack) {
			case .Empty:
				assert(false, "")
			case .Destructure(let (la, ln, lw), let xs):
				if member(ptvar)(la) {
					return do_ { () -> Either<MVar<()>, A> in
						let mid = pthread_self()
						let localmap = !readMVar(_tva.localContent)
						let lk = !readIORef(fromSome(lookup(mid)(localmap)))
						!putMVar(ptvar.tvar)(_tva)
						return Either.right(head(lk))
					}
				} else {
					let b : Bool = !isEmptyMVar(_tva.lock)
					if b {
						return do_ { () -> Either<MVar<()>, A> in
							let mid = pthread_self()

							let nl = !takeMVar(_tva.notifyList)
							!putMVar(_tva.notifyList)(insert(mid)(nl))
							let globalC = !readMVar(_tva.globalContent)
							let content_local = !newIORef([globalC])
							let mp = !takeMVar(_tva.localContent)

							let lg2 = TransactionLog(insert(ptvar)(lg.readTVars), [(insert(ptvar)(la), ln, lw)] + lg.tripleStack, lg.lockingSet)
							!writeIORef(log)(v: lg2)
							!putMVar(_tva.localContent)(insert(mid)(content_local)(mp))
							!putMVar(ptvar.tvar)(_tva)
							return Either.right(globalC)
						}
					} else {
						return do_ { () -> Either<MVar<()>, A> in
							let blockvar : MVar<()> = !newEmptyMVar()
							let wq = !takeMVar(_tva.waitingQueue)
							!putMVar(_tva.waitingQueue)([blockvar] + wq)
							!putMVar(ptvar.tvar)(_tva)
							return Either.left(blockvar)
						}
					}
				}

		}

	}
}

func writeTVarWithLog<A>(log : IORef<TransactionLog<A>>)(v : TVar<A>)(x : A) -> IO<()> {
	return do_ {
		let res : Either<MVar<()>, ()> = !tryWriteTVarWithLog(log)(ptvar: v)(con: x)
		switch res.destruct() {
			case .Right(_):
				return IO.pure(())
			case .Left(let blockvar):
				return do_ {
					!takeMVar(blockvar.unBox())
					return writeTVarWithLog(log)(v: v)(x: x)
				}
			}
	}
}

func tryWriteTVarWithLog<A>(log : IORef<TransactionLog<A>>)(ptvar : TVar<A>)(con : A) -> IO<Either<MVar<()>, ()>> {
	return do_ {
		let _tva : ITVar<A> = !takeMVar(ptvar.tvar)
		let lg = !readIORef(log)
		let mid = pthread_self()

		switch destruct(lg.tripleStack) {
			case .Destructure(let (la, ln, lw), let xs):
				if member(ptvar)(la) {
					return do_ { () -> Either<MVar<()>, ()> in
						let mid = pthread_self()
						let localmap = !readMVar(_tva.localContent)
						let ioref_with_old_content = fromSome(lookup(mid)(localmap))
						let lk = !readIORef(fromSome(lookup(mid)(localmap)))
						!writeIORef(ioref_with_old_content)(v: [con] + tail(lk))

						let lg2 = TransactionLog<A>(lg.readTVars, [(la, ln, insert(ptvar)(lw))] + xs, lg.lockingSet)
						!writeIORef(log)(v: lg2)
						!putMVar(ptvar.tvar)(_tva)
						return Either.right(())
					}
				} else {
					let b = !isEmptyMVar(_tva.lock)
					if b {
						return do_ { () -> Either<MVar<()>, ()> in
							let globalC = !readMVar(_tva.globalContent)
							let content_local = !newIORef([con])
							let mp = !takeMVar(_tva.localContent)
							!putMVar(_tva.localContent)(insert(mid)(content_local)(mp))
							let lg2 = TransactionLog(insert(ptvar)(lg.readTVars), [(insert(ptvar)(la), ln, insert(ptvar)(lw))] + xs, lg.lockingSet)
							!writeIORef(log)(v: lg2)
							!putMVar(ptvar.tvar)(_tva)
							return Either.right(())

						}
					} else {
						return do_ { () -> Either<MVar<()>, ()> in
							let blockvar : MVar<()> = !newEmptyMVar()
							let wq = !takeMVar(_tva.waitingQueue)
							!putMVar(_tva.waitingQueue)([blockvar] + wq)
							!putMVar(ptvar.tvar)(_tva)
							return Either.left(blockvar)
						}
					}
				}
			default:
				assert(false, "")
		}
		assert(false, "")
	}
}

func orRetryWithLog<A>(log : IORef<TransactionLog<A>>) -> IO<()> {
	return do_ {
		let lg = !readIORef(log)
		switch destruct(lg.tripleStack) {
			case .Empty:
				assert(false, "")
			case .Destructure(let (la, ln, lw), let xs):
				return do_ {
					let mid = pthread_self()
					!undoubleLocalTVars(mid)(l: elems(la))
					return writeIORef(log)(v: TransactionLog<A>(lg.readTVars, xs, lg.lockingSet))
				}
		}

	}
}

private func undoubleLocalTVars<A>(mid : ThreadID)(l : [TVar<A>]) -> IO<()> {
	return do_ {
		switch destruct(l) {
			case .Empty:
				return IO.pure(())
			case .Destructure(let tv, let xs):
				let _tvany : ITVar<A> = !takeMVar(tv.tvar)
				let localmap = !readMVar(_tvany.localContent)
				switch lookup(mid)(localmap) {
					case .None:
						assert(false, "")
					case .Some(let conp):
						let l = !readIORef(conp)
						!writeIORef(conp)(v: tail(l))
						!putMVar(tv.tvar)(_tvany)
						!putMVar(_tvany.localContent)(localmap)
						return undoubleLocalTVars(mid)(l: xs)
				}

		}
	}
}

func orElseWithLog<A>(log : IORef<TransactionLog<A>>) -> IO<()> {
	return do_ {
		let lg : TransactionLog<A> = !readIORef(log)
		let mid = pthread_self()
		switch destruct(lg.tripleStack) {
			case .Empty:
				assert(false, "")
			case .Destructure(let (la, ln, lw), let xs):
				return do_ {
					!doubleLocalTVars(mid)(l: elems(la))
					return writeIORef(log)(v: TransactionLog<A>(lg.readTVars, [(la, ln, lw)] + [(la, ln, lw)] + xs, lg.lockingSet))
				}
		}
	}
}

private func doubleLocalTVars<A>(mid : ThreadID)(l : [TVar<A>]) -> IO<()> {
	return do_ {
		switch destruct(l) {
			case .Empty:
				return IO.pure(())
			case .Destructure(let tv, let xs):
				let _tvany : ITVar<A> = !takeMVar(tv.tvar)
				let localmap = !takeMVar(_tvany.localContent)
				switch lookup(mid)(localmap) {
					case .None:
						return IO.pure(())
					case .Some(let conp):
						return do_ {
							let lx : [A] = !readIORef(conp)
							!writeIORef(conp)(v: [head(lx)] + [head(lx)] + tail(lx))
							!putMVar(_tvany.localContent)(localmap)
							!putMVar(tv.tvar)(_tvany)
							return doubleLocalTVars(mid)(l: xs)
						}
				}
		}
	}
}

func commit<A>(tlog : IORef<TransactionLog<A>>) -> IO<()> {
	return do_ { () -> () in
		!writeStartWithLog(tlog)
		!writeClearWithLog(tlog)
		!sendRetryWithLog(tlog)
		!writeTVWithLog(tlog)
		!writeTVnWithLog(tlog)
		!writeEndWithLog(tlog)
		!unlockTVWithLog(tlog)
	}
}

private func _writeStartWithLog<A>(log : IORef<TransactionLog<A>>) -> IO<Either<MVar<()>, ()>> {
	return do_ {
		let mid = pthread_self()

		let lg = !readIORef(log)
		switch destruct(lg.tripleStack) {
			case .Empty:
				assert(false, "")
			case .Destructure(let (la, ln, lw), _):
				let t = lg.readTVars
				let xs = union(t)(difference(la)(ln))
				let held = sort(elems(xs))
				let res : Either<MVar<()>, ()> = !grabLocks(mid)(held: held)
				switch res.destruct() {
					case .Right(_):
						return do_ { () -> Either<MVar<()>, ()> in
							let lg2 = TransactionLog<A>(lg.readTVars, lg.tripleStack, xs)
							!writeIORef(log)(v: lg2)
							return Either.right(())
						}
					case .Left(let lock):
						return do_ { () -> Either<MVar<()>, ()> in
							return Either.left(lock.unBox())
						}
				}
		}
	}
}

private func grabLocks<A>(mid : ThreadID)(held : [TVar<A>]) -> IO<Either<MVar<()>, ()>> {
	return do_ {
		switch destruct(held) {
			case .Empty:
				return do_ { Either.right(()) }
			case .Destructure(let ptvar, let xs):
				let mid = pthread_self()
				let _tvany : ITVar<A> = !takeMVar(ptvar.tvar)
				let b = !tryPutMVar(_tvany.lock)(mid)
				if b {
					return do_ { () -> IO<Either<MVar<()>, ()>> in
						putMVar(ptvar.tvar)(_tvany)
						return grabLocks(mid)(held: [ptvar] + held)
					}
				} else {
					return do_ { () -> Either<MVar<()>, ()> in
						let waiton : MVar<()> = !newEmptyMVar()
						let l = !takeMVar(_tvany.waitingQueue)
						!putMVar(_tvany.waitingQueue)(l + [waiton])
						!putMVar(ptvar.tvar)(_tvany)
						!mapM_({ tva in
							do_ { () -> Void in
								let _tv : ITVar<A> = !takeMVar(tva.tvar)
								!takeMVar(_tv.lock)
								!putMVar(tva.tvar)(_tv)
							}
						})(held.reverse())
						return Either.left(waiton)
					}
				}
		}
	}
}

func writeStartWithLog<A>(log : IORef<TransactionLog<A>>) -> IO<()> {
	return do_ { () -> () in
		let res : Either<MVar<()>, ()> = !_writeStartWithLog(log)
		switch res.destruct() {
			case .Left(let lock):
				!takeMVar(lock.unBox())
				!yield()
				!writeStartWithLog(log)
				return ()
			case .Right(_):
				return ()
		}
	}
}

func writeClearWithLog<A>(log : IORef<TransactionLog<A>>) -> IO<()> {
	return do_ {
		let lg : TransactionLog<A> = !readIORef(log)
		let xs = elems(lg.readTVars)
		!iterateClearWithLog(log)(l: xs)
		return writeIORef(log)(v: TransactionLog<A>(empty(), lg.tripleStack, lg.lockingSet))
	}
}

private func iterateClearWithLog<A>(log : IORef<TransactionLog<A>>)(l: [TVar<A>]) -> IO<()> {
	return do_ {
		switch destruct(l) {
			case .Empty:
				return IO.pure(())
			case .Destructure(let tv, let xs):
				return do_ { () -> IO<()> in
					let mid = pthread_self()
					let _tvany : ITVar<A> = !takeMVar(tv.tvar)
					let nl = !takeMVar(_tvany.notifyList)

					!putMVar(_tvany.notifyList)(delete(mid)(nl))
					return putMVar(tv.tvar)(_tvany)
				} >> iterateClearWithLog(log)(l: xs)
		}
	}
}

func notify(l : [ThreadID]) -> IO<()> {
	return do_ {
		switch destruct(l) {
			case .Empty:
				return do_ { () -> () in }
			case .Destructure(let tid, let xs):
//				throwTo(tid)(RetryException())
				return notify(xs)
		}
	}
}

func sendRetryWithLog<A>(log : IORef<TransactionLog<A>>) -> IO<()> {
	return do_ {
		let lg : TransactionLog<A> = !readIORef(log)
		let mid = pthread_self()
		switch destruct(lg.tripleStack) {
			case .Empty:
				assert(false, "")
			case .Destructure(let (la, ln, lw), let xs):
				let openLW : [ThreadID] = !getIDs(elems(lw))(ls: empty())
				return notify(openLW)
		}
	}
}

private func getIDs<A>(l: [TVar<A>])(ls : Set<ThreadID>) -> IO<[ThreadID]> {
	return do_ { () -> IO<[ThreadID]> in
		switch destruct(l) {
			case .Empty:
				return do_ { () -> [ThreadID] in
					return elems(ls)
				}
			case .Destructure(let tv, let xs):
				return getIDs(xs)(ls: union(do_ {  () -> Set<ThreadID> in
					let mid = pthread_self()
					let _tvany : ITVar<A> = !takeMVar(tv.tvar)
					let l = !takeMVar(_tvany.notifyList)
					!putMVar(_tvany.notifyList)(empty())
					!putMVar(tv.tvar)(_tvany)
					return l
				}.unsafePerformIO())(ls))
		}
	}
}

func writeTVWithLog<A>(log : IORef<TransactionLog<A>>) -> IO<()> {
	return do_ {
		let lg : TransactionLog<A> = !readIORef(log)
		let mid = pthread_self()
		switch destruct(lg.tripleStack) {
			case .Empty:
				assert(false, "")
			case .Destructure(let (la, ln, lw), let xs):
				let tobewritten = difference(lw)(ln)
				!writeTVars(elems(tobewritten))
				return writeIORef(log)(v: TransactionLog<A>(lg.readTVars, [(la, ln, empty())] + xs, lg.lockingSet))
		}
	}
}

private func writeTVars<A>(l : [TVar<A>]) -> IO<()> {
	return do_ {
		switch destruct(l) {
			case .Empty:
				return IO.pure(())
			case .Destructure(let tv, let xs):
				let mid = pthread_self()
				let _tvany : ITVar<A> = !takeMVar(tv.tvar)
				let localmap = !takeMVar(_tvany.localContent)
				switch lookup(mid)(localmap) {
					case .None:
						assert(false, "")
					case .Some(let conp):
						let con : [A] = !readIORef(conp)

						!putMVar(_tvany.localContent)(delete(mid)(localmap))
						!takeMVar(_tvany.globalContent)
						!putMVar(_tvany.globalContent)(head(con))
						!putMVar(tv.tvar)(_tvany)
						return writeTVars(xs)
				}
		}

	}
}

func writeTVnWithLog<A>(log : IORef<TransactionLog<A>>) -> IO<()> {
	return do_ {
		let lg : TransactionLog<A> = !readIORef(log)
		let mid = pthread_self()
		switch destruct(lg.tripleStack) {
			case .Empty:
				assert(false, "")
			case .Destructure(let (la, ln, lw), let xs):
				let t = lg.readTVars
				let k = lg.lockingSet
				let toBeWritten = elems(ln)
				!writeNew(toBeWritten)
				return writeIORef(log)(v: TransactionLog<A>(lg.readTVars, [(la, empty(), lw)] + xs, lg.lockingSet))
		}
	}
}

private func writeNew<A>(l : [TVar<A>]) -> IO<()> {
	return do_ {
		switch destruct(l) {
			case .Empty:
				return IO.pure(())
			case .Destructure(let tv, let xs):
				let mid = pthread_self()
				let _tvany : ITVar<A> = !takeMVar(tv.tvar)
				let lmap = !takeMVar(_tvany.localContent)
				if null(delete(mid)(lmap)) {
					switch lookup(mid)(lmap) {
						case .None:
							assert(false, "")
						case .Some(let conp):
							let con : [A] = !readIORef(conp)

							!takeMVar(_tvany.globalContent)
							!putMVar(_tvany.globalContent)(head(con))
							!putMVar(_tvany.localContent)(empty())
							!putMVar(tv.tvar)(_tvany)
							return writeNew(xs)
					}
				}
				assert(false, "")
		}

	}
}

func writeEndWithLog<A>(log : IORef<TransactionLog<A>>) -> IO<()> {
	return do_ {
		let lg : TransactionLog<A> = !readIORef(log)
		let mid = pthread_self()
		switch destruct(lg.tripleStack) {
			case .Empty:
				assert(false, "")
			case .Destructure(let (la, ln, lw), let xs):
				let l = lg.readTVars
				let k = lg.lockingSet
				return clearEntries(elems(la))
		}
	}
}

func clearEntries<A>(l: [TVar<A>]) -> IO<()> {
	return do_ {
		switch destruct(l) {
			case .Empty:
				return IO.pure(())
			case .Destructure(let tv, let xs):
				let mid = pthread_self()
				let _tvany : ITVar<A> = !takeMVar(tv.tvar)
				let localmap = !takeMVar(_tvany.localContent)
				!putMVar(_tvany.localContent)(delete(mid)(localmap))
				return putMVar(tv.tvar)(_tvany)
		}
	}
}

func unlockTVWithLog<A>(log : IORef<TransactionLog<A>>) -> IO<()> {
	return do_ {
		let lg : TransactionLog<A> = !readIORef(log)
		let mid = pthread_self()
		switch destruct(lg.tripleStack) {
			case .Empty:
				assert(false, "")
			case .Destructure(let (la, ln, lw), let xs):
				let k = lg.lockingSet
				!unlockTVars(elems(k))
				return writeIORef(log)(v: TransactionLog<A>(lg.readTVars, lg.tripleStack, empty()))
		}
	}
}

func unlockTVars<A>(l : [TVar<A>]) -> IO<()> {
	return do_ {
		switch destruct(l) {
			case .Empty:
				return IO.pure(())
			case .Destructure(let tv, let xs):
				let _tvany : ITVar<A> = !takeMVar(tv.tvar)
				let wq = !takeMVar(_tvany.waitingQueue)

				!takeMVar(_tvany.lock)
				!mapM_({ mv in putMVar(mv)(()) })(wq)
				return putMVar(tv.tvar)(_tvany)
		}
	}
}
