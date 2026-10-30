abi <abi/4.0>,
include <tunables/global>

profile enroot /usr/bin/enroot-nsenter flags=(unconfined) {
    allow userns create,
    include if exists <local/enroot>
}
