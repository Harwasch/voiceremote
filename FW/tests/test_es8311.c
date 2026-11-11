/* Purpose: check the actual shared board writes, not a mock codec profile.
 * Inputs: es8311_mic.h. Verified by host; analog behavior needs hardware. */
#include <assert.h>
#include <stdio.h>
#include "../boards/es8311_mic.h"
int main(void)
{
    uint8_t registers[256]={0};
    for(unsigned i=0;i<sizeof es8311_mic_regs/sizeof es8311_mic_regs[0];i++) {
        uint8_t reg=es8311_mic_regs[i][0], value=es8311_mic_regs[i][1];
        if(reg==0x12) assert(value==0x02); /* DAC off, output reference disabled. */
        if(reg==0x13) assert(value==0x00); /* HP output never enabled. */
        registers[reg]=value;
    }
    assert(registers[0x12]==0x02 && registers[0x13]==0x00);
    assert(registers[0x0d]==0x01 && registers[0x0e]==0x02); /* analog/PGA/ADC on */
    assert(registers[0x14]==0x1a && registers[0x16]==0x05); /* mic route/gain */
    assert(registers[0x0a]==0x0c && registers[0x44]==0x58); /* left mic */
    assert(registers[0x31]==0x60 && registers[0x32]==0x00); /* still digitally muted */
    puts("ES8311: DAC/HP off throughout init; ADC path unchanged");
}
