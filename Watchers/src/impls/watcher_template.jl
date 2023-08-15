using .Watchers: @watcher_interface!;
@watcher_interface!()

const ThisVal = Val{:this_val}

function ccxt_this_watcher() end

function _fetch!(w::Watcher, ::ThisVal) end

function _init!(w::Watcher, ::ThisVal) end

function _load!(w::Watcher, ::ThisVal) end

function _process!(w::Watcher, ::ThisVal) end

function _start!(w::Watcher, ::ThisVal) end

function _stop!(w::Watcher, ::ThisVal) end
