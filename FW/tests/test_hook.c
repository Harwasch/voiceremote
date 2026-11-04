/* Purpose: verify USB decoder without serial hardware. Inputs: synthetic commands.
 * Verified: host suite; integration still uses production debounce and gates. */
#include "test_hook.h"
#include <assert.h>
int main(void)
{
    vr_test_input_t s={0};
    assert(vr_test_command(&s,'r')==VR_TEST_SELECT && s.capture==2);
    assert(vr_test_command(&s,'o')==VR_TEST_SELECT && !s.capture);
    assert(vr_test_command(&s,'p')==VR_TEST_SELECT && s.capture==1);
    assert(!vr_test_command(&s,'d') && s.ptt);
    assert(!vr_test_command(&s,'u') && !s.ptt);
    assert(vr_test_command(&s,'t')==VR_TEST_MODE);
    assert(vr_test_command(&s,'t')==VR_TEST_MODE);
    assert(vr_test_command(&s,'h')==VR_TEST_HAPTIC);
    assert(vr_test_command(&s,'x')==VR_TEST_REBOOT);
    assert(!vr_test_command(&s,'?') && s.capture==1 && !s.ptt);
}
