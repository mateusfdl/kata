type Props = {
  value: unknown;
};

export function Component({ value }: Props) {
  // kata-expect: no-runtime-type-checks
  if (typeof value === "string") return <p>{value}</p>;

  return <p>Unknown</p>;
}
