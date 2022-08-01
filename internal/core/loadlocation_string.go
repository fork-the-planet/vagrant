// Code generated by "stringer -type=LoadLocation -linecomment ./internal/core"; DO NOT EDIT.

package core

import "strconv"

func _() {
	// An "invalid array index" compiler error signifies that the constant values have changed.
	// Re-run the stringer command to generate them again.
	var x [1]struct{}
	_ = x[VAGRANTFILE_BOX-0]
	_ = x[VAGRANTFILE_BASIS-1]
	_ = x[VAGRANTFILE_PROJECT-2]
	_ = x[VAGRANTFILE_TARGET-3]
	_ = x[VAGRANTFILE_PROVIDER-4]
}

const _LoadLocation_name = "BoxBasisProjectTargetProvider"

var _LoadLocation_index = [...]uint8{0, 3, 8, 15, 21, 29}

func (i LoadLocation) String() string {
	if i >= LoadLocation(len(_LoadLocation_index)-1) {
		return "LoadLocation(" + strconv.FormatInt(int64(i), 10) + ")"
	}
	return _LoadLocation_name[_LoadLocation_index[i]:_LoadLocation_index[i+1]]
}