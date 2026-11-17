import Image from "next/image";

export function DeviceMock() {
  return (
    <div className="flex flex-wrap items-end justify-center gap-5 sm:gap-8">
      <figure className="w-[min(100%,280px)]">
        <div className="overflow-hidden rounded-[2rem] border border-white/15 bg-black p-2 shadow-[0_30px_80px_rgba(0,0,0,0.45)]">
          <Image
            src="/iphone-app.png"
            alt="iSurfSelect on iPhone, showing wave shape, port and starboard, and surf speed"
            width={900}
            height={1718}
            priority
            className="h-auto w-full rounded-[1.45rem]"
          />
        </div>
        <figcaption className="mt-3 text-center text-sm font-medium text-muted">iPhone</figcaption>
      </figure>

      <figure className="w-[148px] shrink-0">
        <div className="relative">
          <div className="absolute top-10 -left-1.5 h-8 w-1.5 rounded-full bg-white/30" />
          <div className="overflow-hidden rounded-[2rem] border border-white/15 bg-[#ed1c24] p-1.5 shadow-[0_24px_60px_rgba(0,0,0,0.4)]">
            <Image
              src="/watch-app.png"
              alt="iSurfSelect on Apple Watch, armed to switch the wave to port"
              width={416}
              height={302}
              className="h-auto w-full rounded-[1.6rem]"
            />
          </div>
        </div>
        <figcaption className="mt-3 text-center text-sm font-medium text-muted">Apple Watch</figcaption>
      </figure>
    </div>
  );
}
